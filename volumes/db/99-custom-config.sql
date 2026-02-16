-- Apply WAL archiving settings via ALTER SYSTEM  
ALTER SYSTEM SET archive_mode = on;  
ALTER SYSTEM SET archive_timeout = '60s';  
ALTER SYSTEM SET archive_command = 'cp %p /var/lib/postgresql/data/wal_archive/%f';  
  
-- Reload configuration to apply changes without restart  
SELECT pg_reload_conf();


