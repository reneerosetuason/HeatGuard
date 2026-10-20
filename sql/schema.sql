-- HeatGuard database schema (MySQL 8.0+)
-- Run with:
--   mysql -u root -p < sql/schema.sql
-- or:
--   python manage.py init-db

CREATE DATABASE IF NOT EXISTS `HeatGuard`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE `HeatGuard`;

CREATE TABLE IF NOT EXISTS `locations` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(120) NOT NULL,
    `latitude` DECIMAL(9, 6) NOT NULL,
    `longitude` DECIMAL(9, 6) NOT NULL,
    `timezone` VARCHAR(64) NOT NULL DEFAULT 'Asia/Manila',
    `is_active` TINYINT(1) NOT NULL DEFAULT 1,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_locations_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `readings` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `location_id` INT UNSIGNED NOT NULL,
    `observed_at` DATETIME NOT NULL COMMENT 'UTC observation time reported by Open-Meteo',
    `fetched_at` DATETIME NOT NULL COMMENT 'UTC time the API response was received',
    `temperature_c` DECIMAL(5, 2) NOT NULL,
    `humidity_pct` DECIMAL(5, 2) NOT NULL,
    `heat_index_c` DECIMAL(5, 2) NOT NULL,
    `risk_key` VARCHAR(32) NOT NULL,
    `risk_label` VARCHAR(64) NOT NULL,
    `source` VARCHAR(40) NOT NULL DEFAULT 'open-meteo',
    `api_timezone` VARCHAR(64) NULL,
    `raw_payload` JSON NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_readings_location_observed` (`location_id`, `observed_at`),
    KEY `idx_readings_location_observed` (`location_id`, `observed_at`),
    KEY `idx_readings_risk` (`risk_key`),
    CONSTRAINT `fk_readings_location`
        FOREIGN KEY (`location_id`) REFERENCES `locations` (`id`)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `alerts` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `location_id` INT UNSIGNED NOT NULL,
    `reading_id` BIGINT UNSIGNED NOT NULL,
    `risk_key` VARCHAR(32) NOT NULL,
    `risk_label` VARCHAR(64) NOT NULL,
    `temperature_c` DECIMAL(5, 2) NOT NULL,
    `humidity_pct` DECIMAL(5, 2) NOT NULL,
    `heat_index_c` DECIMAL(5, 2) NOT NULL,
    `observed_at` DATETIME NOT NULL,
    `generated_at` DATETIME NOT NULL,
    `message` VARCHAR(500) NOT NULL,
    `recommendations` JSON NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_alerts_reading_risk` (`location_id`, `reading_id`, `risk_key`),
    KEY `idx_alerts_location_generated` (`location_id`, `generated_at`),
    CONSTRAINT `fk_alerts_location`
        FOREIGN KEY (`location_id`) REFERENCES `locations` (`id`)
        ON DELETE CASCADE,
    CONSTRAINT `fk_alerts_reading`
        FOREIGN KEY (`reading_id`) REFERENCES `readings` (`id`)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `monitoring_status` (
    `location_id` INT UNSIGNED NOT NULL,
    `last_attempt_at` DATETIME NULL,
    `last_success_at` DATETIME NULL,
    `last_observed_at` DATETIME NULL,
    `last_error_at` DATETIME NULL,
    `last_error_message` TEXT NULL,
    `consecutive_failures` INT UNSIGNED NOT NULL DEFAULT 0,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`location_id`),
    CONSTRAINT `fk_monitoring_status_location`
        FOREIGN KEY (`location_id`) REFERENCES `locations` (`id`)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `mobile_push_subscriptions` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `endpoint_hash` CHAR(64) NOT NULL,
    `endpoint` TEXT NOT NULL,
    `p256dh` VARCHAR(200) NOT NULL,
    `auth` VARCHAR(100) NOT NULL,
    `location_id` INT UNSIGNED NOT NULL,
    `notify_time` TIME NOT NULL DEFAULT '08:00:00',
    `timezone` VARCHAR(64) NOT NULL,
    `last_sent_date` DATE NULL,
    `last_attempt_at` DATETIME NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_mobile_push_endpoint_hash` (`endpoint_hash`),
    KEY `idx_mobile_push_location` (`location_id`),
    CONSTRAINT `fk_mobile_push_location`
        FOREIGN KEY (`location_id`) REFERENCES `locations` (`id`)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Default monitoring locations. Coordinates are approximate city centres.
INSERT INTO `locations` (`name`, `latitude`, `longitude`, `timezone`, `is_active`)
VALUES
    ('Metro Manila', 14.599500, 120.984200, 'Asia/Manila', 1),
    ('Cebu City', 10.315700, 123.885400, 'Asia/Manila', 1),
    ('Davao City', 7.190700, 125.455300, 'Asia/Manila', 1),
    ('Baguio City', 16.402300, 120.596000, 'Asia/Manila', 1),
    ('Laoag City', 18.197800, 120.593600, 'Asia/Manila', 1)
ON DUPLICATE KEY UPDATE
    `latitude` = VALUES(`latitude`),
    `longitude` = VALUES(`longitude`),
    `timezone` = VALUES(`timezone`),
    `is_active` = VALUES(`is_active`);
