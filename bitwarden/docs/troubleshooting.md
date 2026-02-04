# Bitwarden Troubleshooting Guide

Common issues and solutions for Bitwarden deployment.

## Common Issues

### 1. Services Won't Start

**Symptoms:**
- Docker containers exit immediately
- Health check fails
- Cannot access web interface

**Diagnosis:**
```bash
# Check container status
docker-compose ps

# Check logs
docker-compose logs

# Check specific service
docker-compose logs api
```

**Solutions:**

**Missing Environment Variables:**
```bash
# Check environment file
cat /opt/bitwarden/.env

# Verify required variables are set
grep -E "(DOMAIN|INSTALLATION_ID|DB_PASSWORD)" .env
```

**Database Connection Issues:**
```bash
# Check database container
docker-compose logs db

# Test database connectivity
docker-compose exec api ping db
```

**Port Conflicts:**
```bash
# Check if port 80 is in use
sudo netstat -tlnp | grep :80

# Stop conflicting services
sudo systemctl stop apache2 nginx
```

### 2. Health Check Failures

**Symptoms:**
- ALB shows unhealthy targets
- `/alive` endpoint returns errors
- Intermittent connection issues

**Diagnosis:**
```bash
# Test health endpoint locally
curl -v http://localhost/alive

# Check nginx configuration
docker-compose exec nginx nginx -t

# Check nginx logs
docker-compose logs nginx
```

**Solutions:**

**Nginx Configuration Issues:**
```bash
# Validate nginx config
docker-compose exec nginx nginx -t

# Reload nginx configuration
docker-compose exec nginx nginx -s reload
```

**Service Discovery Issues:**
```bash
# Check internal network connectivity
docker-compose exec nginx ping web
docker-compose exec nginx ping api

# Restart networking
docker-compose down && docker-compose up -d
```

### 3. Database Issues

**Symptoms:**
- Login failures
- Data not persisting
- Database connection errors

**Diagnosis:**
```bash
# Check database container
docker-compose logs db

# Check database files
docker-compose exec db ls -la /var/opt/mssql/data/

# Test SQL connectivity
docker-compose exec db /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P "$DB_PASSWORD" -Q "SELECT @@VERSION"
```

**Solutions:**

**Database Corruption:**
```bash
# Stop services
docker-compose down

# Remove corrupted volume (⚠️  DATA LOSS)
docker volume rm bitwarden_db_data

# Restore from backup
./scripts/restore.sh BACKUP_ID
```

**Password Issues:**
```bash
# Check database password in environment
grep DB_PASSWORD .env

# Reset database password (requires rebuild)
docker-compose down -v
# Update DB_PASSWORD in .env
docker-compose up -d
```

### 4. SSL/TLS Issues

**Symptoms:**
- "Invalid certificate" errors
- Connection refused on HTTPS
- Mixed content warnings

**Diagnosis:**
```bash
# Check ALB configuration
aws elbv2 describe-load-balancers --names your-alb-name

# Test SSL certificate
openssl s_client -connect vault.avniproject.org:443

# Check ALB target health
aws elbv2 describe-target-health --target-group-arn YOUR_TG_ARN
```

**Solutions:**

**ALB Configuration:**
1. Verify ACM certificate is valid
2. Check ALB listeners are configured for HTTPS
3. Ensure target group points to port 80
4. Verify security groups allow ALB → EC2 traffic

**Certificate Renewal:**
- AWS ACM handles automatic renewal
- Verify domain validation records in DNS

### 5. Email/SMTP Issues

**Symptoms:**
- Users can't verify accounts
- Password reset emails not sent
- Admin notifications missing

**Diagnosis:**
```bash
# Check SMTP configuration
grep SMTP_ .env

# Check API logs for SMTP errors
docker-compose logs api | grep -i smtp
```

**Solutions:**

**Gmail SMTP Setup:**
```bash
# Use App Password (not regular password)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_SSL=false
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=your-16-character-app-password
```

**Office 365 SMTP:**
```bash
SMTP_HOST=smtp.office365.com
SMTP_PORT=587
SMTP_SSL=false
SMTP_USERNAME=your-email@company.com
SMTP_PASSWORD=your-password
```

### 6. Performance Issues

**Symptoms:**
- Slow login times
- Timeout errors
- High resource usage

**Diagnosis:**
```bash
# Check resource usage
docker stats

# Check disk space
df -h

# Check system load
top
htop
```

**Solutions:**

**Resource Optimization:**
```bash
# Increase container resources in docker-compose.yml
services:
  db:
    deploy:
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 2G
```

**Database Optimization:**
```bash
# Restart database container
docker-compose restart db

# Check database size
docker-compose exec db /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P "$DB_PASSWORD" -Q "SELECT DB_NAME(database_id) AS DatabaseName, (size * 8 / 1024) AS SizeMB FROM sys.master_files"
```

### 7. User Access Issues

**Symptoms:**
- Can't create accounts
- Login failures
- Admin panel access denied

**Diagnosis:**
```bash
# Check user registration settings
grep DISABLE_USER_REGISTRATION .env

# Check admin settings
grep adminSettings .env

# Check API logs
docker-compose logs api | grep -i "user\|login\|auth"
```

**Solutions:**

**Enable User Registration:**
```bash
# In .env file
DISABLE_USER_REGISTRATION=false

# Restart services
docker-compose restart
```

**Admin Access Issues:**
```bash
# Verify admin email in .env
ADMIN_EMAIL=admin@avniproject.org

# Check if user exists in database
docker-compose exec db /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P "$DB_PASSWORD" -Q "SELECT Email FROM vault.dbo.User"
```

## Diagnostic Commands

### System Health Check
```bash
#!/bin/bash
echo "=== Bitwarden System Health Check ==="
echo "Date: $(date)"
echo ""

echo "1. Container Status:"
docker-compose ps
echo ""

echo "2. Service Health:"
curl -s http://localhost/alive && echo "✅ Health check passed" || echo "❌ Health check failed"
echo ""

echo "3. Disk Usage:"
df -h /opt/bitwarden
echo ""

echo "4. Memory Usage:"
free -h
echo ""

echo "5. Docker Resource Usage:"
docker stats --no-stream
echo ""

echo "6. Recent Logs (last 10 lines):"
docker-compose logs --tail=10
```

### Log Analysis
```bash
# Error analysis
docker-compose logs | grep -i error

# Authentication issues
docker-compose logs api | grep -i "auth\|login\|token"

# Database issues
docker-compose logs db | grep -i "error\|fail"

# Network issues
docker-compose logs nginx | grep -i "error\|timeout\|502\|503\|504"
```

### Performance Monitoring
```bash
# Container resource usage
docker-compose top

# Database performance
docker-compose exec db /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P "$DB_PASSWORD" -Q "SELECT * FROM sys.dm_exec_requests WHERE session_id > 50"

# Nginx access patterns
docker-compose logs nginx | tail -100 | awk '{print $7}' | sort | uniq -c | sort -nr
```

## Emergency Procedures

### Emergency Stop
```bash
# Stop all services immediately
docker-compose down

# Force stop if needed
docker-compose kill
```

### Emergency Restore
```bash
# Find latest backup
ls -la /opt/bitwarden/backups/vault_backup_*.bak | tail -1

# Extract backup ID
BACKUP_ID=$(ls /opt/bitwarden/backups/vault_backup_*.bak | tail -1 | grep -o '[0-9]\{8\}_[0-9]\{6\}')

# Restore with confirmation bypass
RESTORE_CONFIRMATION=true ./scripts/restore.sh $BACKUP_ID
```

### Emergency Maintenance Mode
```bash
# Create maintenance page
cat > /tmp/maintenance.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Maintenance</title></head>
<body>
<h1>Bitwarden Maintenance</h1>
<p>Service temporarily unavailable. Please check back in a few minutes.</p>
</body>
</html>
EOF

# Replace nginx with maintenance page
docker run -d --name maintenance -p 80:80 -v /tmp/maintenance.html:/usr/share/nginx/html/index.html nginx:alpine
```

## Getting Help

### Internal Support
1. Check this troubleshooting guide
2. Review deployment documentation
3. Check recent changes in git history
4. Contact DevOps team

### External Support
1. Bitwarden Community Forum: https://community.bitwarden.com/
2. Bitwarden Help Center: https://bitwarden.com/help/
3. Docker Documentation: https://docs.docker.com/
4. AWS ALB Documentation: https://docs.aws.amazon.com/elasticloadbalancing/

### Log Collection for Support
```bash
# Collect all relevant logs
mkdir -p /tmp/bitwarden-logs
cd /opt/bitwarden

# Export container logs
docker-compose logs > /tmp/bitwarden-logs/container-logs.txt

# Export system info
docker-compose ps > /tmp/bitwarden-logs/container-status.txt
docker system df > /tmp/bitwarden-logs/docker-disk-usage.txt
df -h > /tmp/bitwarden-logs/disk-usage.txt
free -h > /tmp/bitwarden-logs/memory-usage.txt

# Export configuration (remove secrets)
cp .env /tmp/bitwarden-logs/environment.txt
sed -i 's/PASSWORD=.*/PASSWORD=***REDACTED***/g' /tmp/bitwarden-logs/environment.txt
sed -i 's/KEY=.*/KEY=***REDACTED***/g' /tmp/bitwarden-logs/environment.txt

# Create archive
tar czf bitwarden-support-$(date +%Y%m%d-%H%M%S).tar.gz -C /tmp bitwarden-logs/
```