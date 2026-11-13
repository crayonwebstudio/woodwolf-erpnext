# Woodwolf ERPNext - custom production image
# Base: official ERPNext image, pinned. Frappe Framework v16.55.2 inside it.
# Extra apps are pinned to mutually compatible stable releases (verified
# 2026-11-13 via git ls-remote against each official repo):
#   ERPNext     v16.55.0  (in the base image)
#   HRMS        v16.53.2  (branch/tag v16.53.2)
#   CRM         v16.0.3   (v16 line, NOT the default develop branch)
#   Helpdesk    v16.1.0   (v16 line, NOT the default develop branch)
#   Wiki        v3.5.0    (version-3 line, the v16-compatible Wiki line;
#                          Wiki has no version-16 branch or v16 tag)
#   Payments    develop   (no tags, no version-16 branch; required by ERPNext
#                          payment features, and the v16-supported line)
#   Telephony   develop   (no tags; mandatory dependency of Helpdesk,
#                          must be installed on the site before Helpdesk)
FROM frappe/erpnext:v16.55.0

USER frappe
WORKDIR /home/frappe/frappe-bench

RUN mkdir -p sites \
    && printf '{\n  "socketio_port": 9000\n}\n' > sites/common_site_config.json \
    && printf 'frappe\nerpnext\n' > sites/apps.txt

# Fetch each extra app only if it is not already in the base image, so a
# rebuild stays idempotent if Frappe later bundles one of them.
RUN if [ ! -d apps/payments ]; then bench get-app https://github.com/frappe/payments --branch develop --skip-assets; fi \
    && if [ ! -d apps/hrms ]; then bench get-app https://github.com/frappe/hrms --branch v16.53.2 --skip-assets; fi \
    && if [ ! -d apps/telephony ]; then bench get-app https://github.com/frappe/telephony --branch develop --skip-assets; fi \
    && if [ ! -d apps/helpdesk ]; then bench get-app https://github.com/frappe/helpdesk --branch v16.1.0 --skip-assets; fi \
    && if [ ! -d apps/crm ]; then bench get-app https://github.com/frappe/crm --branch v16.0.3 --skip-assets; fi \
    && if [ ! -d apps/wiki ]; then bench get-app https://github.com/frappe/wiki --branch v3.5.0 --skip-assets; fi

RUN ls -1 apps > sites/apps.txt \
    && bench build --apps payments,hrms,telephony,helpdesk,crm,wiki

# Daily backup script, run by the `backup` compose service.
COPY --chown=frappe:frappe backup.sh /home/frappe/frappe-bench/backup.sh
RUN chmod +x /home/frappe/frappe-bench/backup.sh
