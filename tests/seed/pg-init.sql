CREATE TABLE users (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE
);

CREATE TABLE orders (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id INT NOT NULL,
  amount NUMERIC(10,2) NOT NULL
);

-- Tricky data for cross-engine escaping tests (flag exercises boolean mapping).
CREATE TABLE notes (
  id INT PRIMARY KEY,
  body TEXT,
  flag BOOLEAN
);

INSERT INTO notes (id, body, flag) VALUES
  (1, 'plain', true),
  (2, E'tab\tsep', false),
  (3, E'line1\nline2', NULL),
  (4, E'quote " comma , backslash \\\\ 한글', true),
  (5, NULL, NULL),
  (6, '', false);

-- Binary data for cross-engine hex-encoding tests (incl. NUL byte + empty).
CREATE TABLE files (
  id INT PRIMARY KEY,
  data BYTEA
);

INSERT INTO files (id, data) VALUES
  (1, '\xdeadbeef'),
  (2, NULL),
  (3, '\x'),
  (4, '\x00ff10ab');

INSERT INTO users (name, email) VALUES
  ('Alice', 'alice@example.com'),
  ('Bob', 'bob@example.com'),
  ('Carol', 'carol@example.com'),
  ('Dave', 'dave@example.com'),
  ('Eve', 'eve@example.com');

INSERT INTO orders (user_id, amount) VALUES
  (1, 10.00), (1, 25.50), (2, 7.99), (3, 100.00), (3, 3.25), (4, 49.90), (5, 12.00);
