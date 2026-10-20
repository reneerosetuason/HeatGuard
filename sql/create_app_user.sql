-- Least-privilege MySQL account for the HeatGuard web application.
-- Run this once as a MySQL administrator, replacing the password below.
-- The schema itself should be created with: python manage.py init-db

CREATE USER IF NOT EXISTS 'heatguard_app'@'localhost'
    IDENTIFIED BY 'replace-with-a-long-random-password';

GRANT SELECT, INSERT, UPDATE, DELETE
    ON `HeatGuard`.*
    TO 'heatguard_app'@'localhost';

FLUSH PRIVILEGES;

-- Then set these values in .env:
--   DB_USER=heatguard_app
--   DB_PASSWORD=replace-with-a-long-random-password
-- Do not use MySQL root for the running web application.
