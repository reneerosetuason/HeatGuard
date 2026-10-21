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
