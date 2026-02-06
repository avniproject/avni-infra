# Avni Superset Docker Image Build Guide

## Overview

The Avni Superset image extends the official Apache Superset image with custom branding and configuration.

## Build Process

### 1. Update Dockerfile
- Specify the target Apache Superset version using `ARG TAG=<version>`
- Add any version-specific dependencies or configuration changes
- Ensure compatibility with the target version's requirements

### 2. Update Configuration
- Review `assets/superset_config.py` for any deprecated or new configuration options
- Check Apache Superset release notes for breaking changes
- Update feature flags as needed for new functionality

### 3. Build and Test
- Build the Docker image locally using the Makefile or docker build command
- Test the image with appropriate environment variables
- Verify branding (logo, favicon) and core functionality

### 4. Push to Registry
- Tag the image appropriately with the version number
- Push to AWS ECR repository
- Multiple versions can coexist in ECR (e.g., 4.0.1, 6.0.0)

### 5. Deploy
- Pull the new image on the target server
- Stop the existing container
- Run the new container with production environment variables
- Execute database migrations if upgrading major versions
- Verify the deployment

## Important Considerations

- **Database Migrations**: Major version upgrades typically require running `superset db upgrade`
- **Breaking Changes**: Always review the official Superset release notes for breaking changes
- **Dependencies**: Newer versions may require additional system packages or Python dependencies
- **Configuration**: Theme configuration and feature flags may change between versions

## Resources

- Check the Dockerfile and Makefile in this directory for specific commands
- Refer to Apache Superset documentation for version-specific requirements
- Review commit history for examples of past upgrades

---

**Last Updated**: February 2026