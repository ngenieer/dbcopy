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

INSERT INTO users (name, email) VALUES
  ('Alice', 'alice@example.com'),
  ('Bob', 'bob@example.com'),
  ('Carol', 'carol@example.com'),
  ('Dave', 'dave@example.com'),
  ('Eve', 'eve@example.com');

INSERT INTO orders (user_id, amount) VALUES
  (1, 10.00), (1, 25.50), (2, 7.99), (3, 100.00), (3, 3.25), (4, 49.90), (5, 12.00);
