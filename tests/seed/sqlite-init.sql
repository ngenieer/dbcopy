CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE
);

CREATE TABLE orders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  amount NUMERIC NOT NULL
);

CREATE INDEX idx_orders_user ON orders (user_id);

-- Tricky data for cross-engine escaping tests.
CREATE TABLE notes (
  id INTEGER PRIMARY KEY,
  body TEXT
);

INSERT INTO notes (id, body) VALUES
  (1, 'plain'),
  (2, 'tab' || char(9) || 'sep'),
  (3, 'line1' || char(10) || 'line2'),
  (4, 'quote " comma , backslash \ 한글'),
  (5, NULL),
  (6, '');

-- Binary data for cross-engine hex-encoding tests (incl. NUL byte + empty).
CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  data BLOB
);

INSERT INTO files (id, data) VALUES
  (1, X'DEADBEEF'),
  (2, NULL),
  (3, X''),
  (4, X'00FF10AB');

INSERT INTO users (name, email) VALUES
  ('Alice', 'alice@example.com'),
  ('Bob', 'bob@example.com'),
  ('Carol', 'carol@example.com'),
  ('Dave', 'dave@example.com'),
  ('Eve', 'eve@example.com');

INSERT INTO orders (user_id, amount) VALUES
  (1, 10.00), (1, 25.50), (2, 7.99), (3, 100.00), (3, 3.25), (4, 49.90), (5, 12.00);
