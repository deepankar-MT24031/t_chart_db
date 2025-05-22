-- init.sql

-- Create the schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS treatment_chart;

-- Enable pgcrypto extension for gen_random_uuid() if not already enabled
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

--------------------------------------------------------------------------------
-- Helper function for automatically updating 'last_updated' timestamp columns
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION treatment_chart.update_last_updated_column()
RETURNS TRIGGER AS $$
BEGIN
   NEW.last_updated = CURRENT_TIMESTAMP; -- Or NOW()
   RETURN NEW;
END;
$$ language 'plpgsql';

--------------------------------------------------------------------------------
-- Table: all_beds
-- Stores all available bed numbers and their occupancy status.
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS treatment_chart.all_beds (
    bed_number INTEGER PRIMARY KEY,
    occupied BOOLEAN NOT NULL DEFAULT FALSE
);

--------------------------------------------------------------------------------
-- Function and Trigger to enforce sequential bed number increment for all_beds
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION treatment_chart.check_sequential_bed_number()
RETURNS TRIGGER AS $$
DECLARE
    max_bed_number INTEGER;
BEGIN
    -- It's crucial that operations adding beds are serialized or handle concurrency carefully.
    -- This lock is strong; for high-concurrency bed additions (unlikely), review this.
    LOCK TABLE treatment_chart.all_beds IN SHARE ROW EXCLUSIVE MODE; -- Lock to prevent concurrent checks/inserts from seeing stale max

    SELECT COALESCE(MAX(ab.bed_number), 0) INTO max_bed_number
    FROM treatment_chart.all_beds ab;

    IF NEW.bed_number != (max_bed_number + 1) THEN
        RAISE EXCEPTION 'New bed_number (%) must be exactly one greater than the current maximum bed_number (%). Current max is %.', NEW.bed_number, (max_bed_number + 1), max_bed_number;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_check_sequential_bed_number ON treatment_chart.all_beds;
CREATE TRIGGER trigger_check_sequential_bed_number
BEFORE INSERT ON treatment_chart.all_beds
FOR EACH ROW
EXECUTE FUNCTION treatment_chart.check_sequential_bed_number();

--------------------------------------------------------------------------------
-- Initial population of all_beds table with 16 beds
--------------------------------------------------------------------------------
DO $$
BEGIN
    -- Temporarily disable the trigger for initial bulk insert if it causes issues with max_bed_number logic during loop
    -- ALTER TABLE treatment_chart.all_beds DISABLE TRIGGER trigger_check_sequential_bed_number; -- Optional

    FOR i IN 1..16 LOOP
        -- This insert will respect the trigger if not disabled.
        -- If trigger is active, it will only allow 1, then 2, etc.
        -- For initial setup, it's simpler if we ensure no beds exist or handle it.
        -- The ON CONFLICT assumes bed_number is unique and handles reruns.
        -- The trigger expects sequential insertion.
        IF NOT EXISTS (SELECT 1 FROM treatment_chart.all_beds WHERE bed_number = i) THEN
             -- If we are here, it means we are populating from 0 or current max is i-1
             IF i = 1 OR EXISTS (SELECT 1 FROM treatment_chart.all_beds WHERE bed_number = i-1) THEN
                INSERT INTO treatment_chart.all_beds (bed_number, occupied)
                VALUES (i, FALSE)
                ON CONFLICT (bed_number) DO NOTHING;
             ELSE
                -- This case implies a gap, which the trigger should prevent for manual inserts.
                -- For initial population, we just insert if it doesn't exist.
                -- To be safe with the trigger, one might insert 1, then 2...
                -- For simplicity here, assuming the trigger handles this or this is initial setup.
                -- A direct loop without trigger (disable/enable) is cleaner for initial population.
             END IF;
        END IF;
    END LOOP;

    -- Re-enable trigger if it was disabled
    -- ALTER TABLE treatment_chart.all_beds ENABLE TRIGGER trigger_check_sequential_bed_number; -- Optional
END $$;
-- A simpler way for initial population if trigger is active and table is empty:
-- INSERT INTO treatment_chart.all_beds (bed_number) SELECT generate_series(1,16) ON CONFLICT DO NOTHING;
-- However, generate_series in one go might conflict with row-level trigger logic if not handled by disabling.
-- The loop above is more explicit if trigger remains active. Best is disable trigger for bulk setup.
-- For now, let's assume the DO block handles it or beds 1-16 are inserted sequentially if table is empty.
-- If beds 1-N are already there, this loop won't add new ones unless they are N+1, N+2, etc. sequentially.

--------------------------------------------------------------------------------
-- Helper function and Trigger for synchronizing all_beds.occupied status
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION treatment_chart.synchronize_bed_occupancy(p_bed_number INTEGER)
RETURNS VOID AS $$
BEGIN
    IF p_bed_number IS NULL THEN
        RETURN;
    END IF;

    UPDATE treatment_chart.all_beds ab
    SET occupied = EXISTS (
        SELECT 1 FROM treatment_chart.patient p
        WHERE p.bed_number = ab.bed_number -- check against the bed_number from all_beds row being updated
    )
    WHERE ab.bed_number = p_bed_number;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION treatment_chart.trigger_synchronize_bed_occupancy()
RETURNS TRIGGER AS $$
BEGIN
    -- After INSERT or UPDATE on patient table
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        -- Synchronize status for the new bed assignment, if any
        PERFORM treatment_chart.synchronize_bed_occupancy(NEW.bed_number);
    END IF;

    -- After DELETE or UPDATE on patient table
    IF (TG_OP = 'DELETE' OR TG_OP = 'UPDATE') THEN
        -- Synchronize status for the old bed, if any,
        -- and if it's different from the new bed (in case of UPDATE)
        IF OLD.bed_number IS NOT NULL AND (TG_OP = 'DELETE' OR OLD.bed_number IS DISTINCT FROM NEW.bed_number) THEN
            PERFORM treatment_chart.synchronize_bed_occupancy(OLD.bed_number);
        END IF;
    END IF;
    RETURN NULL; -- Result is ignored for AFTER triggers
END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------------------------------
-- Table: patient
-- Stores patient demographic and administrative information.
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS treatment_chart.patient (
    uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    uhid VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    age_in_months VARCHAR(50),
    age_in_years VARCHAR(50),
    sex VARCHAR(10),
    application_uuid UUID NOT NULL,
    bed_number INTEGER, -- Now references all_beds
    last_updated TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT patient_uhid_key UNIQUE (uhid),
    CONSTRAINT fk_patient_bed FOREIGN KEY (bed_number)
        REFERENCES treatment_chart.all_beds(bed_number)
        ON UPDATE CASCADE  -- If a bed_number in all_beds changes (unlikely), update here
        ON DELETE RESTRICT -- Prevent deleting a bed from all_beds if a patient is in it
                           -- Alternatively, ON DELETE SET NULL to make patient bedless if bed is deleted
);

-- Trigger to update 'last_updated' timestamp on patient record update
DROP TRIGGER IF EXISTS trigger_patient_last_updated ON treatment_chart.patient;
CREATE TRIGGER trigger_patient_last_updated
BEFORE UPDATE ON treatment_chart.patient
FOR EACH ROW
EXECUTE FUNCTION treatment_chart.update_last_updated_column();

-- Trigger to update bed occupancy in all_beds table
DROP TRIGGER IF EXISTS trigger_patient_bed_occupancy ON treatment_chart.patient;
CREATE TRIGGER trigger_patient_bed_occupancy
AFTER INSERT OR UPDATE OR DELETE ON treatment_chart.patient
FOR EACH ROW
EXECUTE FUNCTION treatment_chart.trigger_synchronize_bed_occupancy();

--------------------------------------------------------------------------------
-- Table: diagnosis
-- Stores diagnoses associated with a patient.
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS treatment_chart.diagnosis (
    diagnosis_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uuid UUID REFERENCES treatment_chart.patient(uuid) ON DELETE CASCADE,
    diagnosis_text VARCHAR(1000),
    consultants VARCHAR(255),
    jr VARCHAR(255),
    sr VARCHAR(255),
    last_updated TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Trigger to update 'last_updated' timestamp on diagnosis record update
DROP TRIGGER IF EXISTS trigger_diagnosis_last_updated ON treatment_chart.diagnosis;
CREATE TRIGGER trigger_diagnosis_last_updated
BEFORE UPDATE ON treatment_chart.diagnosis
FOR EACH ROW
EXECUTE FUNCTION treatment_chart.update_last_updated_column();

--------------------------------------------------------------------------------
-- Table: observation
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS treatment_chart.observation (
    observation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    diagnosis_id UUID REFERENCES treatment_chart.diagnosis(diagnosis_id) ON DELETE SET NULL,
    prescription_date VARCHAR(255) NOT NULL,
    prescription_time VARCHAR(255) NOT NULL,
    weight VARCHAR(50),
    length VARCHAR(50),
    bsa VARCHAR(50),
    tfr VARCHAR(50),
    tfv VARCHAR(50),
    ivm VARCHAR(50),
    ivf VARCHAR(50),
    feeds VARCHAR(255),
    gir_mg_kg_min VARCHAR(50),
    k_plus VARCHAR(50),
    egfr VARCHAR(50),
    extra_metric JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

--------------------------------------------------------------------------------
-- Table: extra_table
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS treatment_chart.extra_table (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    json_content JSONB
);

--------------------------------------------------------------------------------
-- Detail Treatment Tables (linked to observation)
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS treatment_chart.respiratory_support (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    rate VARCHAR(100),
    volume VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS treatment_chart.sedation (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    dose VARCHAR(100),
    volume VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS treatment_chart.inotropes (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    dose VARCHAR(100),
    volume VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS treatment_chart.antimicrobials (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    day VARCHAR(50),
    dose VARCHAR(100),
    volume VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS treatment_chart.iv_fluid (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    rate VARCHAR(100),
    volume VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS treatment_chart.feeds (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    volume VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS treatment_chart.other_medications (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    dose VARCHAR(100),
    volume VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS treatment_chart.supportive_care (
    id SERIAL PRIMARY KEY,
    observation_id UUID REFERENCES treatment_chart.observation(observation_id) ON DELETE CASCADE,
    content VARCHAR(1000),
    rate VARCHAR(100),
    volume VARCHAR(100)
);

--------------------------------------------------------------------------------
-- Grant permissions (adjust 'admin' user as needed)
--------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA treatment_chart TO admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA treatment_chart TO admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA treatment_chart TO admin;

-- Grant execute on functions
GRANT EXECUTE ON FUNCTION treatment_chart.update_last_updated_column() TO admin;
GRANT EXECUTE ON FUNCTION treatment_chart.check_sequential_bed_number() TO admin;
GRANT EXECUTE ON FUNCTION treatment_chart.synchronize_bed_occupancy(INTEGER) TO admin;
GRANT EXECUTE ON FUNCTION treatment_chart.trigger_synchronize_bed_occupancy() TO admin;

--------------------------------------------------------------------------------
-- Add Indexes for performance
--------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_diagnosis_patient_uuid ON treatment_chart.diagnosis(patient_uuid);
CREATE INDEX IF NOT EXISTS idx_observation_diagnosis_id ON treatment_chart.observation(diagnosis_id);
CREATE INDEX IF NOT EXISTS idx_respiratory_support_obs_id ON treatment_chart.respiratory_support(observation_id);
CREATE INDEX IF NOT EXISTS idx_sedation_obs_id ON treatment_chart.sedation(observation_id);
CREATE INDEX IF NOT EXISTS idx_inotropes_obs_id ON treatment_chart.inotropes(observation_id);
CREATE INDEX IF NOT EXISTS idx_antimicrobials_obs_id ON treatment_chart.antimicrobials(observation_id);
CREATE INDEX IF NOT EXISTS idx_iv_fluid_obs_id ON treatment_chart.iv_fluid(observation_id);
CREATE INDEX IF NOT EXISTS idx_feeds_obs_id ON treatment_chart.feeds(observation_id);
CREATE INDEX IF NOT EXISTS idx_other_medications_obs_id ON treatment_chart.other_medications(observation_id);
CREATE INDEX IF NOT EXISTS idx_supportive_care_obs_id ON treatment_chart.supportive_care(observation_id);
CREATE INDEX IF NOT EXISTS idx_extra_table_obs_id ON treatment_chart.extra_table(observation_id);
CREATE INDEX IF NOT EXISTS idx_patient_bed_number ON treatment_chart.patient(bed_number); -- Index for FK

--------------------------------------------------------------------------------
-- End of script
--------------------------------------------------------------------------------
