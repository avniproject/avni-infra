ARG TAG=v0.60.4.1

FROM --platform=linux/amd64 metabase/metabase:${TAG}

# Tanuh logo (local). Replace assets/logo.png to update.
COPY assets/logo.png /app/branding/logo.png

# Favicon placeholder sourced from the avni-webapp repo until a Tanuh-specific
# favicon is supplied (same pattern as reportingSystem/superset/Dockerfile).
ADD https://github.com/avniproject/avni-webapp/raw/master/public/favicon.ico /app/branding/favicon.ico

EXPOSE 3000
