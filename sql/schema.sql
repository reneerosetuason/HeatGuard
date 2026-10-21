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

-- Add verified mobile accounts without changing monitoring data.
CREATE TABLE IF NOT EXISTS `mobile_users` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `email` VARCHAR(254) NOT NULL,
    `display_name` VARCHAR(80) NOT NULL,
    `password_hash` VARCHAR(255) NOT NULL,
    `email_verified_at` DATETIME NOT NULL,
    `created_at` DATETIME NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_mobile_users_email` (`email`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `mobile_registration_challenges` (
    `challenge_id` VARCHAR(64) NOT NULL,
    `email` VARCHAR(254) NOT NULL,
    `display_name` VARCHAR(80) NOT NULL,
    `password_hash` VARCHAR(255) NOT NULL,
    `code_hash` CHAR(64) NOT NULL,
    `code_expires_at` DATETIME NOT NULL,
    `attempts` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `resend_after` DATETIME NOT NULL,
    `send_count` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `send_window_started_at` DATETIME NOT NULL,
    `created_at` DATETIME NOT NULL,
    PRIMARY KEY (`challenge_id`),
    UNIQUE KEY `uq_mobile_registration_email` (`email`),
    KEY `idx_mobile_registration_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `mobile_user_sessions` (
    `token_hash` CHAR(64) NOT NULL,
    `user_id` BIGINT UNSIGNED NOT NULL,
    `expires_at` DATETIME NOT NULL,
    `created_at` DATETIME NOT NULL,
    PRIMARY KEY (`token_hash`),
    KEY `idx_mobile_sessions_expiry` (`expires_at`),
    KEY `idx_mobile_sessions_user` (`user_id`),
    CONSTRAINT `fk_mobile_sessions_user` FOREIGN KEY (`user_id`)
        REFERENCES `mobile_users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
-- Personal routines and notification inbox. Requires the mobile account tables.
-- Apply with: python manage.py init-mobile-routines
CREATE TABLE IF NOT EXISTS mobile_routines (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    title VARCHAR(80) NOT NULL,
    location_id INT UNSIGNED NOT NULL,
    routine_time TIME NOT NULL,
    weekdays VARCHAR(13) NOT NULL,
    timezone VARCHAR(64) NOT NULL,
    remind_before_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 15,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    revision INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    KEY idx_routines_user (user_id),
    FOREIGN KEY (user_id) REFERENCES mobile_users(id) ON DELETE CASCADE,
    FOREIGN KEY (location_id) REFERENCES locations(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS mobile_notifications (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    routine_id BIGINT UNSIGNED NULL,
    event_at DATETIME NOT NULL,
    title VARCHAR(120) NOT NULL DEFAULT '',
    body TEXT NOT NULL,
    weather_json JSON NULL,
    ai_generated BOOLEAN NOT NULL DEFAULT FALSE,
    state VARCHAR(16) NOT NULL DEFAULT 'preparing',
    claim_token VARCHAR(64) NULL,
    lease_until DATETIME NULL,
    read_at DATETIME NULL,
    created_at DATETIME NOT NULL,
    UNIQUE KEY uq_routine_occurrence (routine_id, event_at),
    KEY idx_notification_inbox (user_id, state, created_at),
    FOREIGN KEY (user_id) REFERENCES mobile_users(id) ON DELETE CASCADE,
    FOREIGN KEY (routine_id) REFERENCES mobile_routines(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS mobile_push_devices (
    token_hash CHAR(64) NOT NULL PRIMARY KEY,
    token TEXT NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    session_hash CHAR(64) NOT NULL,
    platform VARCHAR(16) NOT NULL,
    updated_at DATETIME NOT NULL,
    KEY idx_push_device_user (user_id),
    FOREIGN KEY (user_id) REFERENCES mobile_users(id) ON DELETE CASCADE,
    FOREIGN KEY (session_hash) REFERENCES mobile_user_sessions(token_hash) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS mobile_notification_deliveries (
    notification_id BIGINT UNSIGNED NOT NULL,
    token_hash CHAR(64) NOT NULL,
    state VARCHAR(16) NOT NULL DEFAULT 'pending',
    attempts INT UNSIGNED NOT NULL DEFAULT 0,
    next_attempt_at DATETIME NOT NULL,
    lease_until DATETIME NULL,
    claim_token VARCHAR(64) NULL,
    PRIMARY KEY (notification_id, token_hash),
    KEY idx_delivery_pending (state, next_attempt_at),
    FOREIGN KEY (notification_id) REFERENCES mobile_notifications(id) ON DELETE CASCADE,
    FOREIGN KEY (token_hash) REFERENCES mobile_push_devices(token_hash) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
