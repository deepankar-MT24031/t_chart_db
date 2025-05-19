FROM postgres:16

# Create initialization directory
RUN mkdir -p /docker-entrypoint-initdb.d

# Copy initialization script
COPY init.sql /docker-entrypoint-initdb.d/

# Set proper permissions
RUN chown -R postgres:postgres /docker-entrypoint-initdb.d
