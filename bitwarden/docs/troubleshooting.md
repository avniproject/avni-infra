```bash
ssh bitwarden-prod
sudo su - bitwarden
cd /opt/bitwarden

docker ps

docker logs bitwarden-api
docker logs bitwarden-identity
docker logs bitwarden-nginx

# Check Bitwarden status
./bitwarden.sh status
```

**Solutions:**

**Missing Environment Variables:**
```bash
# Check environment file
cat /opt/bitwarden/bwdata/env/global.override.env

```

**Database Connection Issues:**
```bash
docker logs bitwarden-mssql

docker exec bitwarden-mssql /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "password" -Q "SELECT @@VERSION"
```

### Emergency Backup and Restore

**Create Manual Backup:**
```bash
# SSH to server and switch to bitwarden user
ssh ubuntu@vault.avniproject.org
sudo su - bitwarden
cd /opt/bitwarden

docker exec -i bitwarden-mssql /backup-db.sh
tar czf backups/emergency_backup_$(date +%Y%m%d_%H%M%S).tar.gz bwdata/
ls -la bwdata/mssql/backups/  # Database backups
ls -la backups/               # Configuration backups
```

**Restore from Backup:**
```bash
./bitwarden.sh stop
tar -xzf backups/emergency_backup_YYYYMMDD_HHMMSS.tar.gz
./bitwarden.sh restart
```