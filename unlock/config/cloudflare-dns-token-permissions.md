# Cloudflare DNS-01 API Token permissions

For `DOT_TLS_MODE=letsencrypt`, create a **restricted API Token** in Cloudflare Dashboard:

- **Permissions**
  - `Zone / Zone / Read`
  - `Zone / DNS / Edit`
- **Zone Resources**
  - Include → Specific zone → the zone containing `DOT_DOMAIN`

Put the token only in runtime `.env`:

```env
CF_DNS_API_TOKEN=...
```

Never put it in the Dockerfile, image, Git repository, GitHub Actions output, or screenshots.

The container passes it as `CLOUDFLARE_DNS_API_TOKEN` to `lego` only while creating/renewing the `_acme-challenge.<DOT_DOMAIN>` TXT record.
