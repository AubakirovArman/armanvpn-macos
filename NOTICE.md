# Attribution and modifications

armanVPN macOS — public source snapshot, 2026-10-18.
Copyright (c) 2026 Arman and contributors for original application code.
Source code license: GNU Affero General Public License version 3 only (AGPL-3.0-only).

This project uses or adapts snx-rs 6.5.1 by Dmitry Pankratov and contributors:
https://github.com/ancwrd1/snx-rs
Pinned revision: 86aa48031888050f957af7b6adf2c2e39d4745fd.
Original copyright and license notices are retained.

Local modifications dated 2026-10-15 include the native application UI, certificate-consent handling, local credential storage and connection diagnostics.
The engine patch and its build instructions are in engine/; upstream source is fetched at the pinned revision during the build.

Changes dated 2026-10-18 add the dashboard, Codex account limit reader and read-only Mac hardware monitoring.

The AppleSMC wire layout and read protocol are adapted from Stats by Serhiy Mytrovtsiy and contributors:
https://github.com/exelban/stats
Copyright (c) 2019 Serhiy Mytrovtsiy. Licensed under the MIT License.
The complete notice is retained in armanVPN/Legal/Stats-LICENSE.txt and included in the application.
