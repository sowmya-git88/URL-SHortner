<?php
declare(strict_types=1);

/**
 * Project 06 — Support tickets API. Front controller: Nginx sends every /api/* request here
 * through the PHP-FPM Unix socket; we route on method + path ourselves.
 */
require __DIR__ . '/bootstrap.php';

set_exception_handler(function (Throwable $e): void {
    error_log('[tickets] ' . get_class($e) . ': ' . $e->getMessage());
    $code = $e instanceof PDOException ? 503 : 500;
    json_out(['error' => $code === 503 ? 'database unavailable' : 'internal error'], $code);
});

$method = $_SERVER['REQUEST_METHOD'];
$path   = rtrim(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?: '/', '/');

const STATUSES   = ['open', 'pending', 'resolved', 'closed'];
const PRIORITIES = ['low', 'normal', 'high', 'urgent'];

// ---------- health ----------
if ($method === 'GET' && $path === '/api/health') {
    $t0 = microtime(true);
    try {
        db()->query('SELECT 1')->fetchColumn();
        $ok = true;
        $err = null;
    } catch (Throwable $e) {
        $ok = false;
        $err = $e->getMessage();
    }
    json_out([
        'status'    => $ok ? 'ok' : 'degraded',
        'database'  => 'aiven-mysql',
        'db_ok'     => $ok,
        'db_ms'     => round((microtime(true) - $t0) * 1000, 1),
        'php'       => PHP_VERSION,
        'sapi'      => PHP_SAPI,
        'pid'       => getmypid(),
        'user'      => posix_getpwuid(posix_geteuid())['name'] ?? 'unknown',
        'https'     => is_https(),
        'error'     => $err,
    ], $ok ? 200 : 503);
}

// ---------- auth ----------
if ($method === 'POST' && $path === '/api/login') {
    $in = json_in();
    $stmt = db()->prepare('SELECT id, email, name, password_hash FROM agents WHERE email = ?');
    $stmt->execute([trim((string)($in['email'] ?? ''))]);
    $agent = $stmt->fetch();
    if (!$agent || !password_verify((string)($in['password'] ?? ''), $agent['password_hash'])) {
        error_log('[tickets] failed login for ' . substr((string)($in['email'] ?? ''), 0, 80) . ' from ' . ($_SERVER['REMOTE_ADDR'] ?? '?'));
        usleep(300000);
        json_out(['error' => 'invalid credentials'], 401);
    }
    start_session();
    session_regenerate_id(true);
    $_SESSION['agent'] = ['id' => (int)$agent['id'], 'email' => $agent['email'], 'name' => $agent['name']];
    json_out(['agent' => $_SESSION['agent']]);
}

if ($method === 'POST' && $path === '/api/logout') {
    start_session();
    $_SESSION = [];
    session_destroy();
    json_out(['ok' => true]);
}

if ($method === 'GET' && $path === '/api/me') {
    start_session();
    json_out(['agent' => $_SESSION['agent'] ?? null]);
}

// ---------- tickets ----------
if ($method === 'POST' && $path === '/api/tickets') {
    $in = json_in();
    $subject   = trim((string)($in['subject'] ?? ''));
    $body      = trim((string)($in['body'] ?? ''));
    $requester = trim((string)($in['requester'] ?? ''));
    $priority  = in_array($in['priority'] ?? 'normal', PRIORITIES, true) ? $in['priority'] : 'normal';
    if ($subject === '' || mb_strlen($subject) > 160 || $body === '' || !filter_var($requester, FILTER_VALIDATE_EMAIL)) {
        json_out(['error' => 'subject (≤160), body and a valid requester email are required'], 422);
    }
    $stmt = db()->prepare('INSERT INTO tickets(subject, body, requester, priority) VALUES (?, ?, ?, ?)');
    $stmt->execute([$subject, $body, $requester, $priority]);
    json_out(['id' => (int)db()->lastInsertId(), 'status' => 'open'], 201);
}

if ($method === 'GET' && $path === '/api/tickets') {
    require_agent();
    $status = $_GET['status'] ?? '';
    if ($status !== '' && in_array($status, STATUSES, true)) {
        $stmt = db()->prepare('SELECT t.*, a.name AS assignee FROM tickets t LEFT JOIN agents a ON a.id = t.assignee_id WHERE t.status = ? ORDER BY FIELD(t.priority, \'urgent\', \'high\', \'normal\', \'low\'), t.id DESC LIMIT 200');
        $stmt->execute([$status]);
    } else {
        $stmt = db()->query('SELECT t.*, a.name AS assignee FROM tickets t LEFT JOIN agents a ON a.id = t.assignee_id ORDER BY t.id DESC LIMIT 200');
    }
    $counts = db()->query('SELECT status, COUNT(*) AS n FROM tickets GROUP BY status')->fetchAll(PDO::FETCH_KEY_PAIR);
    json_out(['tickets' => $stmt->fetchAll(), 'counts' => $counts]);
}

if (preg_match('#^/api/tickets/(\d+)$#', $path, $m)) {
    $id = (int)$m[1];
    if ($method === 'GET') {
        require_agent();
        $stmt = db()->prepare('SELECT t.*, a.name AS assignee FROM tickets t LEFT JOIN agents a ON a.id = t.assignee_id WHERE t.id = ?');
        $stmt->execute([$id]);
        $ticket = $stmt->fetch() ?: json_out(['error' => 'not found'], 404);
        $c = db()->prepare('SELECT id, author, is_agent, body, created_at FROM comments WHERE ticket_id = ? ORDER BY id');
        $c->execute([$id]);
        $ticket['comments'] = $c->fetchAll();
        json_out($ticket);
    }
    if ($method === 'PATCH') {
        $agent = require_agent();
        $in = json_in();
        $sets = [];
        $args = [];
        if (isset($in['status']) && in_array($in['status'], STATUSES, true)) {
            $sets[] = 'status = ?';
            $args[] = $in['status'];
        }
        if (isset($in['priority']) && in_array($in['priority'], PRIORITIES, true)) {
            $sets[] = 'priority = ?';
            $args[] = $in['priority'];
        }
        if (!empty($in['assign_to_me'])) {
            $sets[] = 'assignee_id = ?';
            $args[] = $agent['id'];
        }
        if (!$sets) {
            json_out(['error' => 'nothing to update'], 422);
        }
        $args[] = $id;
        $stmt = db()->prepare('UPDATE tickets SET ' . implode(', ', $sets) . ' WHERE id = ?');
        $stmt->execute($args);
        json_out(['ok' => true, 'updated' => $stmt->rowCount()]);
    }
}

if ($method === 'POST' && preg_match('#^/api/tickets/(\d+)/comments$#', $path, $m)) {
    $agent = require_agent();
    $body = trim((string)(json_in()['body'] ?? ''));
    if ($body === '') {
        json_out(['error' => 'body required'], 422);
    }
    $stmt = db()->prepare('INSERT INTO comments(ticket_id, author, is_agent, body) VALUES (?, ?, 1, ?)');
    $stmt->execute([(int)$m[1], $agent['name'], $body]);
    json_out(['id' => (int)db()->lastInsertId()], 201);
}

json_out(['error' => 'no such endpoint', 'path' => $path], 404);
