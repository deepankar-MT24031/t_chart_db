-- Ensure the schema exists
CREATE SCHEMA IF NOT EXISTS treatment_chart;

-- 1. patient (no foreign keys to other tables in this set)
CREATE TABLE treatment_chart.patient (
    uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    uhid VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    age_in_months VARCHAR,
    age_in_years VARCHAR,
    sex VARCHAR,
    application_uuid UUID NOT NULL,
    CONSTRAINT patient_uhid_key UNIQUE (uhid) -- From your notebook's cell 5 output
);

-- 2. diagnosis (references patient)
CREATE TABLE treatment_chart.diagnosis (
    diagnosis_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uuid UUID REFERENCES treatment_chart.patient(uuid),
    diagnosis_text VARCHAR,
    consultants VARCHAR,
    jr VARCHAR,
    sr VARCHAR
);

-- 3. observation (references diagnosis)
CREATE TABLE treatment_chart.observation (
    observation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    diagnosis_id UUID REFERENCES treatment_chart.diagnosis(diagnosis_id),
    prescription_date VARCHAR NOT NULL, -- As per your schema output
    prescription_time VARCHAR NOT NULL, -- As per your schema output
    weight VARCHAR,
    length VARCHAR,
    bsa VARCHAR,
    tfr VARCHAR,
    tfv VARCHAR,
    ivm VARCHAR,
    ivf VARCHAR,
    feeds VARCHAR,
    gir_mg_kg_min VARCHAR,
    k_plus VARCHAR,
    egfr VARCHAR,
    extra_metric JSONB,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Detail tables referencing observation

-- 4. inotropes
CREATE TABLE treatment_chart.inotropes (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.inotropes_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    content VARCHAR,
    dose VARCHAR,
    volume VARCHAR
);
-- If sequence doesn't exist and you want auto-creation:
-- CREATE TABLE treatment_chart.inotropes (
--     id SERIAL PRIMARY KEY,
--     ...
-- );
-- Note: You'd need to create the sequence 'treatment_chart.inotropes_id_seq' separately if not using SERIAL.

-- 5. respiratory_support
CREATE TABLE treatment_chart.respiratory_support (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.respiratory_support_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    content VARCHAR,
    rate VARCHAR,
    volume VARCHAR
);

-- 6. sedation
CREATE TABLE treatment_chart.sedation (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.sedation_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    content VARCHAR,
    dose VARCHAR,
    volume VARCHAR
);

-- 7. iv_fluid
CREATE TABLE treatment_chart.iv_fluid (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.iv_fluid_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    content VARCHAR,
    rate VARCHAR,
    volume VARCHAR
);

-- 8. extra_table
CREATE TABLE treatment_chart.extra_table (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.extra_table_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    json_content JSONB
);

-- 9. other_medications
CREATE TABLE treatment_chart.other_medications (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.other_medications_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    content VARCHAR,
    dose VARCHAR,
    volume VARCHAR
);

-- 10. antimicrobials
CREATE TABLE treatment_chart.antimicrobials (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.antimicrobials_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    content VARCHAR,
    day VARCHAR,
    dose VARCHAR,
    volume VARCHAR
);

-- 11. feeds
CREATE TABLE treatment_chart.feeds (
    id INTEGER PRIMARY KEY DEFAULT nextval('treatment_chart.feeds_id_seq'::regclass),
    observation_id UUID REFERENCES treatment_chart.observation(observation_id),
    content VARCHAR,
    volume VARCHAR
);
