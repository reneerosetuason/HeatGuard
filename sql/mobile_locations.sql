-- Private addresses for verified mobile accounts.
-- Apply with: python manage.py init-mobile-locations
CREATE TABLE IF NOT EXISTS mobile_saved_locations (
    location_id INT UNSIGNED NOT NULL PRIMARY KEY,
    user_id BIGINT UNSIGNED NULL,
    display_name VARCHAR(120) NOT NULL,
    created_at DATETIME NOT NULL,
    UNIQUE KEY uq_saved_location_name (user_id, display_name),
    FOREIGN KEY (location_id) REFERENCES locations(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES mobile_users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
