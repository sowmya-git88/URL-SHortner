<?php
// php db/seed.php  — creates tables, the first agent account and two demo tickets.
declare(strict_types=1);
require __DIR__ . '/../api/bootstrap.php';

$pdo = db();
$sql = file_get_contents(__DIR__ . '/schema.sql');
foreach (array_filter(array_map('trim', explode(';', $sql))) as $stmt) {
    $pdo->exec($stmt);
}
echo "schema ok\n";

$email = env('SEED_AGENT_EMAIL', 'agent@example.com');
$pass  = env('SEED_AGENT_PASSWORD', '');
if (strlen($pass) < 10) {
    fwrite(STDERR, "SEED_AGENT_PASSWORD must be at least 10 characters\n");
    exit(1);
}
$stmt = $pdo->prepare('INSERT IGNORE INTO agents(email, name, password_hash) VALUES (?, ?, ?)');
$stmt->execute([$email, 'Support Agent', password_hash($pass, PASSWORD_DEFAULT)]);
echo "agent ok: {$email}\n";

if ((int)$pdo->query('SELECT COUNT(*) FROM tickets')->fetchColumn() === 0) {
    $ins = $pdo->prepare('INSERT INTO tickets(subject, body, requester, priority) VALUES (?, ?, ?, ?)');
    $ins->execute(['Cannot log in to VPN', 'Since this morning the VPN client says "auth failed".', 'ravi@example.com', 'high']);
    $ins->execute(['Request: new laptop', 'My laptop battery lasts 20 minutes.', 'meera@example.com', 'normal']);
    echo "demo tickets ok\n";
}
