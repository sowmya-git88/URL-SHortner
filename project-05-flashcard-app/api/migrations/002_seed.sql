INSERT INTO decks(name)
SELECT 'Linux memory (demo)'
WHERE NOT EXISTS (SELECT 1 FROM decks WHERE name = 'Linux memory (demo)');

INSERT INTO cards(deck_id, front, back)
SELECT d.id, v.front, v.back
FROM decks d
CROSS JOIN (VALUES
  ('What does exit code 137 mean?', '128 + 9 → the process was killed by SIGKILL, very often by the OOM killer.'),
  ('Command to show RAM and swap in human units?', 'free -h'),
  ('Which file makes swap persistent across reboots?', '/etc/fstab  (/swapfile none swap sw 0 0)'),
  ('What does vm.swappiness=10 do?', 'Tells the kernel to strongly prefer dropping page cache over swapping anonymous memory.'),
  ('Where do you see OOM kills?', 'dmesg / journalctl -k  → "Out of memory: Killed process …"'),
  ('Why chmod 600 /swapfile?', 'Swap can contain secrets from RAM; only root may read it (swapon warns otherwise).')
) AS v(front, back)
WHERE d.name = 'Linux memory (demo)'
  AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.deck_id = d.id);
