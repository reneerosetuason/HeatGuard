-- Apply to an existing HeatGuard database as a MySQL administrator:
--   mysql -u root -p HeatGuard < sql/mobile_push_subscriptions.sql

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
