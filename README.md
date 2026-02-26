# 🛡️ 3x-ui Database Manager

A powerful, safe, and interactive Bash script to manage, clean, and optimize SQLite databases for **3x-ui** panels on Ubuntu/Debian. 

Designed for server administrators who need to perform bulk actions (like removing expired users or cleaning up specific email ranges) without manually editing the database.

---

## 🚀 Quick Install

Run the following command in your terminal. The script handles dependencies automatically.

```bash
bash <(curl -s https://raw.githubusercontent.com/Crimson-Amir/x-ui-md/main/install.sh)
```

---

## ✨ Features

*   **🔍 Regex Bulk Removal:** Delete hundreds of clients instantly based on Email, UUID, or SubID patterns.
*   **📅 Date-Based Cleanup:** Remove clients expired before a certain date or expiring after a date.
*   **🛡️ Safety First:**
    *   **Auto-Backup:** Creates a backup *before* any change is made.
    *   **Preview Mode:** Shows you exactly which clients matched your search before you delete them.
    *   **Lock Prevention:** Automatically stops/starts x-ui to prevent `database is locked` errors during bulk updates.
*   **🔄 Traffic Reset:** Reset traffic stats for specific users (via Regex) or the entire server.
*   **💾 Backup Manager:** Restore previous states or manage/delete old backups easily.
*   **⚡ Optimization:** Vacuum the SQLite database to reduce file size and improve performance.

---

## 📖 Usage Guide & Examples

### 1. Regex Removal Examples
When you choose "Remove Clients (Regex)", you can use powerful patterns. Here are common examples:

| Goal | Regex Pattern | Explanation |
| :--- | :--- | :--- |
| **Number Range (5000-5999)** | `^5[0-9]{3}$` | Matches any 4-digit number starting with 5. |
| **Number Range (100-199)** | `^1[0-9]{2}$` | Matches any 3-digit number starting with 1. |
| **Specific Word (Contains)** | `test` | Matches `test_user`, `mytest`, `123test`. |
| **Starts With** | `^vip_.*` | Matches `vip_ali`, `vip_sara`. |
| **Exact Match** | `^user1$` | Matches exactly `user1` and nothing else. |
| **Standard UUIDs** | `^[0-9a-f]{8}-` | Matches standard UUID formats (starts with 8 hex chars). |

### 2. Date Removal
*   **Timezone:** You can input your local timezone (e.g., `Asia/Tehran`) or leave empty for UTC.
*   **Format:** Dates must be in `YYYY-MM-DD HH:MM:SS` format (e.g., `2026-02-26 14:30:00`).

---

## ⚠️ Requirements
*   Root access (`sudo`).
*   Ubuntu / Debian operating system.
*   Installed packages: `sqlite3`, `jq`, `curl` (The script installs these automatically if missing).

---
