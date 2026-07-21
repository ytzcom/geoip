# Laravel Integration Guide

How to consume this project's GeoIP databases from a Laravel application, using the same pattern
several production apps already run. It is written so you can **paste everything below the line into
a coding agent** and let it do the wiring, or follow it by hand.

Two facts shape the whole design:

- **Lookups are local and never hit the network.** You read MaxMind `.mmdb` / IP2Location `.bin`
  files on disk with in-process reader libraries. A lookup is a memory-mapped file read, sub-millisecond.
- **Refresh is out-of-band.** A separate process (a Docker entrypoint + cron, or a scheduled artisan
  command) downloads fresh databases from the authenticated **geoipdb.net** API on a schedule. The
  API hands out short-lived presigned URLs from the operator's private S3 bucket — see the
  [project README](../README.md) and [docs/GITHUB_ACTION.md](GITHUB_ACTION.md).

You need a **GeoIP API key** (issued by the operator of the geoipdb.net deployment you're pointing
at) before any of this works.

---

## Agent prompt

> **Task:** Integrate GeoIP (MaxMind + IP2Location) into this Laravel app so that `geoip($ip)`
> returns country/city/ISP/proxy data from local database files, refreshed automatically from the
> geoipdb.net API. Follow the steps below. Do not commit database files to git. Assume an existing
> Laravel 10/11/12 app. Placeholders: `{{GEOIP_API_ENDPOINT}}` defaults to
> `https://geoipdb.net/auth`; the API key comes from the `GEOIP_API_KEY` env var.

### 1. Install packages

```bash
composer require torann/geoip:^3.0 geoip2/geoip2:^3.0 \
  ip2location/ip2location-php:^9.7 ip2location/ip2proxy-php:^4.1
php artisan vendor:publish --provider="Torann\GeoIP\GeoIPServiceProvider" --tag=config
```

- `torann/geoip` — the Laravel wrapper: `geoip($ip)` helper, caching, driver system.
- `geoip2/geoip2` — reads MaxMind `.mmdb` (pulls in `maxmind-db/reader`).
- `ip2location/ip2location-php` — reads IP2Location `.bin` (DB23: city/ISP/lat-lon).
- `ip2location/ip2proxy-php` — reads the PX2 `.bin` (proxy/VPN detection).

> If you only need **country/city** (not ISP or proxy detection), stop after `torann/geoip` +
> `geoip2/geoip2` and use torann's built-in `maxmind_database` service against `GeoIP2-City.mmdb`.
> The hybrid driver below only earns its keep when you also need ISP and proxy data merged in.

### 2. Environment

Add to `.env` / `.env.example`:

```env
# geoipdb.net API — download/refresh only (not used at lookup time)
GEOIP_API_KEY=
GEOIP_API_ENDPOINT=https://geoipdb.net/auth
GEOIP_TARGET_DIR=            # optional; defaults to database_path('geoip')
GEOIP_DATABASES=all         # or a comma list, e.g. "GeoIP2-Country.mmdb,GeoIP2-City.mmdb"

# Docker refresh knobs (see §5) — safe defaults shown
GEOIP_DOWNLOAD_ON_START=true
GEOIP_VALIDATE_ON_START=true
GEOIP_SETUP_CRON=true
GEOIP_UPDATE_SCHEDULE=0 2 * * *
```

Databases land in `database/geoip/` with these exact filenames (they match what the pipeline uploads):

| File | Provider | Gives you |
|------|----------|-----------|
| `GeoIP2-City.mmdb` | MaxMind | city, region, postal, lat/lon |
| `GeoIP2-Country.mmdb` | MaxMind | country only (small; good for country-only apps) |
| `GeoIP2-ISP.mmdb` | MaxMind | ISP / organization |
| `GeoIP2-Connection-Type.mmdb` | MaxMind | connection type |
| `IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN` | IP2Location (DB23) | IPv4 full record |
| `IPV6-...-USAGETYPE.BIN` | IP2Location (DB23) | IPv6 full record |
| `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN` | IP2Location (PX2) | proxy/VPN detection |

> **Disk cost:** the full set is ~2 GB compressed, ~7 GB on disk. Pull only what you use via
> `GEOIP_DATABASES` — country geo-gating needs just `GeoIP2-Country.mmdb` (~8 MB).

### 3. Configure `config/geoip.php`

Set the default service and add an `updater` block the artisan command reads. This is the verified
shape from the reference apps:

```php
'service' => 'maxmind_ip2location',

// Read by the geoip:update command (§5)
'updater' => [
    'api_key'    => env('GEOIP_API_KEY', ''),
    'endpoint'   => env('GEOIP_API_ENDPOINT', 'https://geoipdb.net/auth'),
    'target_dir' => env('GEOIP_TARGET_DIR', database_path('geoip')),
    'databases'  => env('GEOIP_DATABASES', 'all'),
],

'services' => [
    // ...torann's built-in services stay as published...

    'maxmind_ip2location' => [
        'class' => App\Drivers\GeoIP\MaxMindIp2Location::class,
        'database_path' => [
            'maxmind' => [
                'city'           => env('GEO_MAXMIND_CITY', database_path('geoip/GeoIP2-City.mmdb')),
                'country'        => env('GEO_MAXMIND_COUNTRY', database_path('geoip/GeoIP2-Country.mmdb')),
                'connectionType' => env('GEO_MAXMIND_CONNECTION_TYPE', database_path('geoip/GeoIP2-Connection-Type.mmdb')),
                'isp'            => env('GEO_MAXMIND_ISP', database_path('geoip/GeoIP2-ISP.mmdb')),
            ],
            'ip2location' => [
                'ipv4' => env('GEO_IP2LOCATION_IPV4', database_path('geoip/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN')),
                'ipv6' => env('GEO_IP2LOCATION_IPV6', database_path('geoip/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN')),
            ],
            'ip2location_proxy' => [
                'proxy' => env('GEO_IP2LOCATION_PROXY', database_path('geoip/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN')),
            ],
        ],
        'locales' => ['en'],
    ],
],
```

### 4. The hybrid driver

`torann/geoip` drivers extend `Torann\GeoIP\Services\AbstractService` and implement `locate($ip): Location`.
The hybrid opens all three readers once, then merges per lookup — **MaxMind wins** on conflicts,
IP2Location fills the gaps and adds proxy data. Skeleton to flesh out (`app/Drivers/GeoIP/MaxMindIp2Location.php`):

```php
<?php

namespace App\Drivers\GeoIP;

use GeoIp2\Database\Reader as MaxMindReader;
use IP2Location\Database as Ip2LocationDb;
use IP2Proxy\Database as Ip2ProxyDb;
use Torann\GeoIP\Location;
use Torann\GeoIP\Services\AbstractService;

class MaxMindIp2Location extends AbstractService
{
    protected array $readers = [];

    public function boot(): void
    {
        $paths = $this->config('database_path');
        $this->readers['city']  = new MaxMindReader($paths['maxmind']['city']);
        $this->readers['isp']   = new MaxMindReader($paths['maxmind']['isp']);
        $this->readers['ip2l']  = new Ip2LocationDb($paths['ip2location']['ipv4'], Ip2LocationDb::FILE_IO);
        $this->readers['proxy'] = new Ip2ProxyDb($paths['ip2location_proxy']['proxy'], Ip2ProxyDb::FILE_IO);
        // Guard each new(): skip a reader whose file is missing so a partial download degrades, not fatals.
    }

    public function locate($ip): Location
    {
        $mm    = $this->readers['city']->city($ip);          // MaxMind: country/city/lat-lon
        $isp   = $this->readers['isp']->isp($ip);            // MaxMind: ISP/org
        $proxy = $this->readers['proxy']->getAll($ip);       // IP2Proxy: is_proxy/proxy_type

        return $this->hydrate([
            'ip'              => $ip,
            'iso_code'        => $mm->country->isoCode,
            'country'         => $mm->country->name,
            'city'            => $mm->city->name,
            'state_name'      => $mm->mostSpecificSubdivision->name,
            'postal_code'     => $mm->postal->code,
            'lat'             => $mm->location->latitude,
            'lon'             => $mm->location->longitude,
            'timezone'        => $mm->location->timeZone,
            'isp'             => $isp->isp ?? $isp->organization,
            'is_proxy'        => ($proxy['isProxy'] ?? 0) > 0,
            'proxy_type'      => $proxy['proxyType'] ?? null,
            // fall back to the IP2Location ipv4/ipv6 reader for any field MaxMind left null
        ]);
    }
}
```

> Wrap each reader lookup in a try/catch for `AddressNotFoundException` — an IP absent from one DB
> must not blow up the merge. The reference apps do this and return whatever the other readers found.

### 5. Refresh the databases

**Docker (recommended — this is what the reference apps run).** Copy the scripts in from the official
image and let the entrypoint download on start + install a cron job:

```dockerfile
COPY --from=ytzcom/geoip-scripts:latest /opt/geoip /opt/geoip
```

```sh
# docker/entrypoint.sh
. /opt/geoip/entrypoint-helper.sh
geoip_init            # downloads if missing, validates, installs the cron schedule (supercronic)
# ...then start php-fpm / the app
```

`geoip_init` honours the env vars from §2: it downloads to `GEOIP_TARGET_DIR` when
`GEOIP_DOWNLOAD_ON_START=true`, validates when `GEOIP_VALIDATE_ON_START=true`, and — when
`GEOIP_SETUP_CRON=true` — runs `GEOIP_UPDATE_SCHEDULE` (default daily 02:00) to refresh with atomic
replacement. Persist the volume so restarts don't re-download 7 GB:

```yaml
volumes:
  - geoip_data:/var/www/html/database/geoip
```

**Non-Docker fallback — artisan + scheduler.** Add a command that shells to the CLI, then schedule it:

```php
// app/Console/Commands/UpdateGeoIpDatabases.php  — signature: geoip:update
$cfg = config('geoip.updater');
// find /opt/geoip/geoip-update-{amd64,arm64} (or geoip-update-posix.sh), then:
exec(sprintf("%s --api-key '%s' --directory '%s' --endpoint '%s' 2>&1",
    $script, $cfg['api_key'], $cfg['target_dir'], $cfg['endpoint']), $out, $code);
```

```php
// routes/console.php (L11+) or Kernel::schedule()
Schedule::command('geoip:update')->weekly()->sundays()->at('03:00');
```

The updater databases are refreshed weekly upstream (Mondays 00:00 UTC), so refreshing the app more
than daily buys nothing. You can also just run the bundled CLI directly:
`./cli/geoip-update.sh -k $GEOIP_API_KEY -d database/geoip` (see [cli/README.md](../cli/README.md)).

### 6. Use it

```php
$loc = geoip('8.8.8.8');   // Torann\GeoIP\Location
$loc->iso_code;            // "US"
$loc->city;                // "Mountain View"
$loc->isp;                 // "Google LLC"
$loc->is_proxy;            // false

// or via a thin service that adds a fallback + swallows AddressNotFoundException:
class GeoIPService
{
    public function detectCountryCode(?string $ip, ?string $fallback = null): ?string
    {
        if (in_array($ip, [null, '', '0'], true)) return $fallback;
        try {
            $loc = GeoIP::getLocation($ip);          // Torann\GeoIP\Facades\GeoIP
            return $loc && ! $loc->default ? strtoupper((string) $loc->iso_code) : $fallback;
        } catch (\GeoIp2\Exception\AddressNotFoundException) {
            return $fallback;
        }
    }
}
```

Typical wiring: a middleware that stamps `$request->geoip = geoip($clientIp)` for downstream
controllers, or a geo-gate that blocks/allows by `->iso_code`. Extract the real client IP from
`X-Forwarded-For` behind a proxy — don't trust `$request->ip()` blindly.

---

## GitHub Action requirements

### Upstream (the operator's pipeline must exist)

`geoip($ip)` only has data because the geoip-updater pipeline keeps the S3 bucket current and the API
serves from it. Whoever runs the geoipdb.net deployment you point at needs the pipeline configured —
repo **secrets** `MAXMIND_LICENSE_KEY`, `IP2LOCATION_TOKEN`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, and **variables** `MAXMIND_ACCOUNT_ID`, `S3_BUCKET`, `AWS_REGION`. Full setup:
[README → Running your own instance](../README.md#-running-your-own-instance). If you're only
*consuming* a hosted endpoint, you just need an API key from that operator — skip this.

### App-side CI (fetch databases in your own workflow)

To bake or cache databases during your app's build/test, use the reusable action with a
`GEOIP_API_KEY` repo secret:

```yaml
- uses: ytzcom/geoip@main
  with:
    api-key: ${{ secrets.GEOIP_API_KEY }}
    databases: GeoIP2-City.mmdb   # pull only what the app uses; "all" is ~2 GB
    directory: database/geoip
    # auth-endpoint defaults to https://geoipdb.net/auth
```

Cache the `database/geoip` directory between runs to avoid re-downloading. **Never commit the
databases to git** (they're large and licensed) — add `database/geoip/` to `.gitignore`. See
[docs/GITHUB_ACTION.md](GITHUB_ACTION.md) for every input.

---

## Verification

1. **Download works:** `php artisan geoip:update` (or start the container) populates
   `database/geoip/` with the expected `.mmdb`/`.BIN` files.
2. **Lookup works:** `php artisan tinker` → `geoip('8.8.8.8')->iso_code` returns `US`.
3. **Proxy detection works** (if PX2 pulled): `geoip('<known-proxy-ip>')->is_proxy` is `true`.
4. **Graceful when a DB is missing:** temporarily point one path at a nonexistent file — a lookup
   should still return the other readers' data, not throw.
5. **Docker:** with `GEOIP_DOWNLOAD_ON_START=true`, the container becomes healthy and
   `docker logs <c> | grep -i geoip` shows a successful download + validation.

For deeper reader examples in raw PHP (no Laravel wrapper), see [USAGE_EXAMPLES.md](../USAGE_EXAMPLES.md).
