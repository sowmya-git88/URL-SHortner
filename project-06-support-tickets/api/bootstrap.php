<?php
declare(strict_types=1);

/**
 * Loads /etc/tickets/tickets.env (KEY=value lines), builds a PDO connection to Aiven MySQL
 * over TLS, and provides small JSON helpers. PHP-FPM runs with clear_env=yes, so we read
 * the file ourselves instead of relying on the process environment.
 */
const ENV_FILE = '/etc/tickets/tickets.env';

function load_env(string $file): array
{
    static $cache = null;
    if ($cache !== null) {
        return $cache;
    }
    $cache = [];
    if (!is_readable($file)) {
        return $cache;
    }
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#' || !str_contains($line, '=')) {
            continue;
        }
        [$k, $v] = array_map('trim', explode('=', $line, 2));
        if (strlen($v) >= 2 && ($v[0] === '"' || $v[0] === "'") && $v[-1] === $v[0]) {
            $v = substr($v, 1, -1);
        }
        $cache[$k] = $v;
    }
    return $cache;
}

function env(string $key, ?string $default = null): ?string
{
    $fromFile = load_env(getenv('TICKETS_ENV_FILE') ?: ENV_FILE);
    return $fromFile[$key] ?? (getenv($key) !== false ? getenv($key) : $default);
}

function db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }
    $dsn = sprintf('mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4',
        env('DB_HOST', '127.0.0.1'), env('DB_PORT', '3306'), env('DB_NAME', 'defaultdb'));
    $options = [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES   => false,
        PDO::ATTR_TIMEOUT            => 5,
    ];
    $ca = env('DB_SSL_CA');
    if ($ca) {
        $options[PDO::MYSQL_ATTR_SSL_CA] = $ca;
        $options[PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT] = true;
    }
    $pdo = new PDO($dsn, env('DB_USER', ''), env('DB_PASS', ''), $options);
    return $pdo;
}

function json_out($data, int $code = 200): never
{
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function json_in(): array
{
    $raw = file_get_contents('php://input') ?: '';
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

function is_https(): bool
{
    return (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');
}

function start_session(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    // Secure cookies only over HTTPS: the raw-IP http:// site would otherwise never get a session.
    session_set_cookie_params([
        'lifetime' => 0,
        'path'     => '/',
        'secure'   => is_https(),
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
    session_name('tickets_sid');
    session_start();
}

function require_agent(): array
{
    start_session();
    if (empty($_SESSION['agent'])) {
        json_out(['error' => 'login required'], 401);
    }
    return $_SESSION['agent'];
}
