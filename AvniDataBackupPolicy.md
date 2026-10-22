# Avni Data backup policy:

All copies stay inside India. The primary is in AWS Mumbai (ap-south-1) and disaster recovery is in AWS Hyderabad (ap-south-2). Hyderabad replaced Singapore on 22 Oct 2026 ([#101](https://github.com/avniproject/avni-infra/issues/101)).

### Avni Prod Database 
- **Point-in-time restore** capability enabled
- **Daily snapshots** captured, with last **14 days** retained in AWS Mumbai (ap-south-1)
- **Cross-region DR**: AWS Backup plan `proddb02-daily-dr` takes a daily backup at 02:00 UTC and copies it to vault `proddb02-dr-vault-hyd` in **AWS Hyderabad (ap-south-2)**, retained for **3 days**
- **Known limit**: the 3-day retention applies even when no newer copy arrives. If Mumbai stops producing backups for more than 3 days, the Hyderabad copies expire too
- DR copies are **KMS-encrypted** with a customer-managed key in Hyderabad (`alias/rds-dr-hyderabad`)
- A restore from the Hyderabad copy was tested on 21 Oct 2026. The snapshot is on PostgreSQL 16.8, which Hyderabad does not offer for new databases, and it still restored

### Avni Prod Media Content
- **Versioning** enabled — all file versions retained indefinitely
- **Cross-region replication** enabled to bucket `prod-user-media-dr-hyderabad` in **AWS Hyderabad (ap-south-2)**, stored as Standard-IA
- **Delete isolation**: Deletes on the primary bucket do **not** propagate to the DR copy. Tested on 21 Oct 2026
- All existing data (~1.4 TB, ~2.5M file versions) has been synced to the DR bucket
- Encrypted at rest with S3-managed keys (SSE-S3), on both the primary and the DR bucket

### Summary

| Component | Primary (Mumbai) | DR (Hyderabad) |
|-----------|-----------------|----------------|
| **Database** | 14-day automated backups + point-in-time restore | Daily encrypted copies, 3-day retention |
| **Media Content** | Versioned, delete-protected | Real-time cross-region replica, delete-isolated |

Both primary and DR locations are within AWS India but in **geographically separate regions** (Mumbai and Hyderabad), providing protection against regional outages and disasters.
