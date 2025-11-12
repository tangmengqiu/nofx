BEGIN;
PRAGMA writable_schema = on;
PRAGMA encoding = 'UTF-8';
PRAGMA page_size = '4096';
PRAGMA auto_vacuum = '0';
PRAGMA user_version = '0';
PRAGMA application_id = '0';
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE ai_models (
			id TEXT PRIMARY KEY,
			user_id TEXT NOT NULL DEFAULT 'default',
			name TEXT NOT NULL,
			provider TEXT NOT NULL,
			enabled BOOLEAN DEFAULT 0,
			api_key TEXT DEFAULT '',
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, custom_api_url TEXT DEFAULT '', custom_model_name TEXT DEFAULT '',
			FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
		);
CREATE TABLE user_signal_sources (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			user_id TEXT NOT NULL,
			coin_pool_url TEXT DEFAULT '',
			oi_top_url TEXT DEFAULT '',
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
			UNIQUE(user_id)
		);
CREATE TABLE traders (
			id TEXT PRIMARY KEY,
			user_id TEXT NOT NULL DEFAULT 'default',
			name TEXT NOT NULL,
			ai_model_id TEXT NOT NULL,
			exchange_id TEXT NOT NULL,
			initial_balance REAL NOT NULL,
			scan_interval_minutes INTEGER DEFAULT 3,
			is_running BOOLEAN DEFAULT 0,
			btc_eth_leverage INTEGER DEFAULT 5,
			altcoin_leverage INTEGER DEFAULT 5,
			trading_symbols TEXT DEFAULT '',
			use_coin_pool BOOLEAN DEFAULT 0,
			use_oi_top BOOLEAN DEFAULT 0,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, custom_prompt TEXT DEFAULT '', override_base_prompt BOOLEAN DEFAULT 0, is_cross_margin BOOLEAN DEFAULT 1, use_default_coins BOOLEAN DEFAULT 1, custom_coins TEXT DEFAULT '', system_prompt_template TEXT DEFAULT 'default', total_realized_pnl REAL DEFAULT 0, total_commission REAL DEFAULT 0, initial_position_cost REAL DEFAULT 0,
			FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
			FOREIGN KEY (ai_model_id) REFERENCES ai_models(id),
			FOREIGN KEY (exchange_id) REFERENCES exchanges(id)
		);
CREATE TABLE users (
			id TEXT PRIMARY KEY,
			email TEXT UNIQUE NOT NULL,
			password_hash TEXT NOT NULL,
			otp_secret TEXT,
			otp_verified BOOLEAN DEFAULT 0,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
		);
CREATE TABLE system_config (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
		);
CREATE TABLE beta_codes (
			code TEXT PRIMARY KEY,
			used BOOLEAN DEFAULT 0,
			used_by TEXT DEFAULT '',
			used_at DATETIME DEFAULT NULL,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		);
CREATE TABLE "exchanges" (
			id TEXT NOT NULL,
			user_id TEXT NOT NULL DEFAULT 'default',
			name TEXT NOT NULL,
			type TEXT NOT NULL,
			enabled BOOLEAN DEFAULT 0,
			api_key TEXT DEFAULT '',
			secret_key TEXT DEFAULT '',
			testnet BOOLEAN DEFAULT 0,
			hyperliquid_wallet_addr TEXT DEFAULT '',
			aster_user TEXT DEFAULT '',
			aster_signer TEXT DEFAULT '',
			aster_private_key TEXT DEFAULT '',
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id, user_id),
			FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
		);
INSERT OR IGNORE INTO 'ai_models'(_rowid_, 'id', 'user_id', 'name', 'provider', 'enabled', 'api_key', 'created_at', 'updated_at', 'custom_api_url', 'custom_model_name') VALUES (1, 'deepseek', 'default', 'DeepSeek', 'deepseek', 0, '', '2025-11-11 03:02:28', '2025-11-11 03:02:28', '', '');
INSERT OR IGNORE INTO 'ai_models'(_rowid_, 'id', 'user_id', 'name', 'provider', 'enabled', 'api_key', 'created_at', 'updated_at', 'custom_api_url', 'custom_model_name') VALUES (2, 'qwen', 'default', 'Qwen', 'qwen', 0, '', '2025-11-11 03:02:28', '2025-11-11 03:02:28', '', '');
INSERT OR IGNORE INTO 'ai_models'(_rowid_, 'id', 'user_id', 'name', 'provider', 'enabled', 'api_key', 'created_at', 'updated_at', 'custom_api_url', 'custom_model_name') VALUES (3, '3514e44e-72ef-4e73-9c73-e5d7abd1a9c8_deepseek', '3514e44e-72ef-4e73-9c73-e5d7abd1a9c8', 'DeepSeek', 'deepseek', 1, 'ENC:v1:2uBoO0F6KB5yc/8P:0kEiqE9dZvM7mKP+vUCwegxyZxnxEn7EbJuLgdw20dZgyHhMkN7ZgV0OjTP/Mdzkf6L/', '2025-11-11 03:04:47', '2025-11-11 03:04:47', '', '');
INSERT OR IGNORE INTO 'traders'(_rowid_, 'id', 'user_id', 'name', 'ai_model_id', 'exchange_id', 'initial_balance', 'scan_interval_minutes', 'is_running', 'btc_eth_leverage', 'altcoin_leverage', 'trading_symbols', 'use_coin_pool', 'use_oi_top', 'created_at', 'updated_at', 'custom_prompt', 'override_base_prompt', 'is_cross_margin', 'use_default_coins', 'custom_coins', 'system_prompt_template') VALUES (1, 'hyperliquid_3514e44e-72ef-4e73-9c73-e5d7abd1a9c8_deepseek_1762830374', '3514e44e-72ef-4e73-9c73-e5d7abd1a9c8', 'testBalance', '3514e44e-72ef-4e73-9c73-e5d7abd1a9c8_deepseek', 'hyperliquid', 89.998359, 3, 1, 5, 3, '', 0, 0, '2025-11-11 03:06:16', '2025-11-11 03:16:49', '', 0, 1, 1, '', 'default');
INSERT OR IGNORE INTO 'users'(_rowid_, 'id', 'email', 'password_hash', 'otp_secret', 'otp_verified', 'created_at', 'updated_at') VALUES (1, '3514e44e-72ef-4e73-9c73-e5d7abd1a9c8', 'test1110@mail.com', '$2a$10$4AERASTGZwjKwKvj.UujvurBneLtMCIB/ZJNVGNvHX29pXRq46lgO', '7DTELAHHAWF52QHSKIHGZTU5TEHGBYAO', 1, '2025-11-11 03:04:04', '2025-11-11 03:04:25');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (47, 'max_drawdown', '20.0', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (48, 'altcoin_leverage', '5', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (49, 'api_server_port', '8080', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (50, 'oi_top_api_url', '', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (51, 'stop_trading_minutes', '60', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (52, 'default_coins', '["BTCUSDT","ETHUSDT","SOLUSDT","BNBUSDT","XRPUSDT","DOGEUSDT","ADAUSDT","HYPEUSDT"]', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (53, 'btc_eth_leverage', '5', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (54, 'jwt_secret', 'Qk0kAa+d0iIEzXVHXbNbm+UaN3RNabmWtH8rDWZ5OPf+4GX8pBflAHodfpbipVMyrw1fsDanHsNBjhgbDeK9Jg==', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (55, 'beta_mode', 'false', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (56, 'use_default_coins', 'true', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (57, 'coin_pool_api_url', '', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (58, 'max_daily_loss', '10.0', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'users'(_rowid_, 'id', 'email', 'password_hash', 'otp_secret', 'otp_verified', 'created_at', 'updated_at') VALUES (1, '3514e44e-72ef-4e73-9c73-e5d7abd1a9c8', 'test1110@mail.com', '$2a$10$4AERASTGZwjKwKvj.UujvurBneLtMCIB/ZJNVGNvHX29pXRq46lgO', '7DTELAHHAWF52QHSKIHGZTU5TEHGBYAO', 1, '2025-11-11 03:04:04', '2025-11-11 03:04:25');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (47, 'max_drawdown', '20.0', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (48, 'altcoin_leverage', '5', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (49, 'api_server_port', '8080', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (50, 'oi_top_api_url', '', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (51, 'stop_trading_minutes', '60', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (52, 'default_coins', '["BTCUSDT","ETHUSDT","SOLUSDT","BNBUSDT","XRPUSDT","DOGEUSDT","ADAUSDT","HYPEUSDT"]', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (53, 'btc_eth_leverage', '5', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (54, 'jwt_secret', 'Qk0kAa+d0iIEzXVHXbNbm+UaN3RNabmWtH8rDWZ5OPf+4GX8pBflAHodfpbipVMyrw1fsDanHsNBjhgbDeK9Jg==', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (55, 'beta_mode', 'false', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (56, 'use_default_coins', 'true', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (57, 'coin_pool_api_url', '', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'system_config'(_rowid_, 'key', 'value', 'updated_at') VALUES (58, 'max_daily_loss', '10.0', '2025-11-11 04:08:14');
INSERT OR IGNORE INTO 'exchanges'(_rowid_, 'id', 'user_id', 'name', 'type', 'enabled', 'api_key', 'secret_key', 'testnet', 'hyperliquid_wallet_addr', 'aster_user', 'aster_signer', 'aster_private_key', 'created_at', 'updated_at') VALUES (1, 'binance', 'default', 'Binance Futures', 'binance', 0, '', '', 0, '', '', '', '', '2025-11-11 03:02:28', '2025-11-11 03:02:28');
INSERT OR IGNORE INTO 'exchanges'(_rowid_, 'id', 'user_id', 'name', 'type', 'enabled', 'api_key', 'secret_key', 'testnet', 'hyperliquid_wallet_addr', 'aster_user', 'aster_signer', 'aster_private_key', 'created_at', 'updated_at') VALUES (2, 'hyperliquid', 'default', 'Hyperliquid', 'hyperliquid', 0, '', '', 0, '', '', '', '', '2025-11-11 03:02:28', '2025-11-11 03:02:28');
INSERT OR IGNORE INTO 'exchanges'(_rowid_, 'id', 'user_id', 'name', 'type', 'enabled', 'api_key', 'secret_key', 'testnet', 'hyperliquid_wallet_addr', 'aster_user', 'aster_signer', 'aster_private_key', 'created_at', 'updated_at') VALUES (3, 'aster', 'default', 'Aster DEX', 'aster', 0, '', '', 0, '', '', '', '', '2025-11-11 03:02:28', '2025-11-11 03:02:28');
INSERT OR IGNORE INTO 'exchanges'(_rowid_, 'id', 'user_id', 'name', 'type', 'enabled', 'api_key', 'secret_key', 'testnet', 'hyperliquid_wallet_addr', 'aster_user', 'aster_signer', 'aster_private_key', 'created_at', 'updated_at') VALUES (4, 'hyperliquid', '3514e44e-72ef-4e73-9c73-e5d7abd1a9c8', 'Hyperliquid', 'dex', 1, '789ddb7630902c54f4c6c35a1fd45bde1f4f3a8021de896a64b44769d1cad76c', '', 0, '0x1101993D3099780A212339d1BBD3083d5c55f256', '', '', '', '2025-11-11 03:05:43', '2025-11-11 03:05:43');
DELETE FROM sqlite_sequence;
CREATE TRIGGER update_users_updated_at
			AFTER UPDATE ON users
			BEGIN
				UPDATE users SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
			END;
CREATE TRIGGER update_ai_models_updated_at
			AFTER UPDATE ON ai_models
			BEGIN
				UPDATE ai_models SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
			END;
CREATE TRIGGER update_traders_updated_at
			AFTER UPDATE ON traders
			BEGIN
				UPDATE traders SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
			END;
CREATE TRIGGER update_user_signal_sources_updated_at
			AFTER UPDATE ON user_signal_sources
			BEGIN
				UPDATE user_signal_sources SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
			END;
CREATE TRIGGER update_system_config_updated_at
			AFTER UPDATE ON system_config
			BEGIN
				UPDATE system_config SET updated_at = CURRENT_TIMESTAMP WHERE key = NEW.key;
			END;
CREATE TRIGGER update_exchanges_updated_at
			AFTER UPDATE ON exchanges
			BEGIN
				UPDATE exchanges SET updated_at = CURRENT_TIMESTAMP 
				WHERE id = NEW.id AND user_id = NEW.user_id;
			END;
PRAGMA writable_schema = off;
COMMIT;
