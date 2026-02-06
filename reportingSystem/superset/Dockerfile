ARG TAG=latest

FROM --platform=linux/amd64  apache/superset:${TAG}

# Switch to root to install dependencies
USER root

# Install additional dependencies for 6.0.0
# - chromium and chromium-driver for screenshots/reports
# - PostgreSQL client libraries for psycopg2
RUN apt-get update && \
    apt-get install -y \
        chromium \
        chromium-driver \
        build-essential \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

RUN uv pip install --no-cache \
        psycopg2-binary \
        Pillow

# Switch back to superset user
USER superset

#Copy avni logo and favicon
ADD --chown=superset https://raw.githubusercontent.com/avniproject/avni-website/master/src/img/avni-logo-color.png /app/superset/static/assets/images/avni.png
ADD --chown=superset https://github.com/avniproject/avni-webapp/raw/master/public/favicon.ico  /app/superset/static/assets/images/avni-favicon.ico

# Copy the configuration file, set the environment variable,
COPY --chown=superset ./assets/superset_config.py /app/

#Environment variable
ENV SUPERSET_SECRET_KEY=dummy
ENV SUPERSET_DB_NAME=dummy
ENV SUPERSET_DB_USER=dummy
ENV SUPERSET_DB_PASSWORD=dummy
ENV SUPERSET_DB_URL=dummy
ENV SUPERSET_DB_PORT=dummy
ENV SUPERSET_CONFIG_PATH=/app/superset_config.py


# Expose the port
EXPOSE 8088


# Run superset
ENTRYPOINT ["superset", "run", "-h", "0.0.0.0", "-p", "8088", "--with-threads", "--reload", "--debugger"]