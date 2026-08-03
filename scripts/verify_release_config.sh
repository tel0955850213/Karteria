#!/bin/sh

set -eu

if [ "${CONFIGURATION:-}" != "Release" ]; then
    exit 0
fi

config_plist="${SRCROOT}/Karteria/Info.plist"
worker_url="$(plutil -extract KARTERIA_WORKER_URL raw -o - "${config_plist}")"
support_email="$(plutil -extract KARTERIA_SUPPORT_EMAIL raw -o - "${config_plist}")"
revenuecat_key="$(plutil -extract REVENUECAT_PUBLIC_SDK_KEY raw -o - "${config_plist}")"

case "${worker_url}" in
    https://*) ;;
    *) echo "error: KARTERIA_WORKER_URL must be a production HTTPS endpoint for Release." >&2; exit 1 ;;
esac

case "${support_email}" in
    *@*.*) ;;
    *) echo "error: KARTERIA_SUPPORT_EMAIL must be configured for Release." >&2; exit 1 ;;
esac

case "${revenuecat_key}" in
    appl_*) ;;
    *) echo "error: REVENUECAT_PUBLIC_SDK_KEY must be an Apple public SDK key for Release." >&2; exit 1 ;;
esac
