# Avni Data backup policy:

### Avni Prod Database 
- **Point-in-time restore** capability enabled
- **Daily snapshots** captured, with last **35 days** retained in AWS Mumbai (ap-south-1)
- **Cross-region DR**: Daily snapshot copies replicated to **AWS Singapore (ap-southeast-1)**, with minimum **3 days retention** — recovery points are retained longer if newer backups are unavailable
- Snapshots are **KMS-encrypted** in both regions

### Avni Prod Media Content
- **Versioning** enabled — all file versions retained indefinitely
- **Cross-region replication** enabled to **AWS Singapore (ap-southeast-1)** for disaster recovery
- **Delete protection**: Bucket policy prevents accidental deletion of objects by any IAM user (only root account can delete)
- **Delete isolation**: Deletes on the primary bucket do **not** propagate to the DR copy
- All existing data (~1.4 TB, ~1.9M files) has been synced to the DR bucket

### Summary

| Component | Primary (Mumbai) | DR (Singapore) |
|-----------|-----------------|----------------|
| **Database** | 35-day automated backups + point-in-time restore | Daily encrypted snapshot copies, 3-day minimum retention |
| **Media Content** | Versioned, delete-protected | Real-time cross-region replica, delete-isolated |

Both primary and DR locations are within AWS but in **geographically separate regions** (Mumbai and Singapore), providing protection against regional outages and disasters.
