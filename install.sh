#!/bin/bash

# ==============================================================================
# 3x-ui Database Manager & Cleaner
# Repo: https://github.com/Crimson-Amir/x-ui-md
# Environment: Ubuntu / Debian
# Dependencies: sqlite3, jq, curl
# ==============================================================================

# --- Colors & UI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# --- Variables ---
DEFAULT_DB_PATH="/etc/x-ui/x-ui.db"
BACKUP_DIR="/root/x-ui-backups"
DB_PATH=""
TEMP_DIR="/tmp/xui_manager_tmp"

# --- Utility Functions ---

function print_banner() {
    clear
    echo -e "${CYAN}"
    echo "██╗  ██╗       ██╗   ██╗██╗    ███╗   ███╗██████╗ "
    echo "╚██╗██╔╝       ██║   ██║██║    ████╗ ████║██╔══██╗"
    echo " ╚███╔╝ █████╗ ██║   ██║██║    ██╔████╔██║██║  ██║"
    echo " ██╔██╗ ╚════╝ ██║   ██║██║    ██║╚██╔╝██║██║  ██║"
    echo "██╔╝ ██╗       ╚██████╔╝██║    ██║ ╚═╝ ██║██████╔╝"
    echo "╚═╝  ╚═╝        ╚═════╝ ╚═╝    ╚═╝     ╚═╝╚═════╝ "
    echo -e "${NC}"
    echo -e "${BLUE}Advanced Database Manager for 3x-ui${NC}"
    echo -e "${BLUE}https://github.com/Crimson-Amir/x-ui-md${NC}"
    echo -e "${YELLOW}System Time: $(date)${NC}"
    echo "----------------------------------------------------"
}

function msg_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
function msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
function msg_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
function msg_err() { echo -e "${RED}[ERROR]${NC} $1"; }

function check_root() {
    if [ "$EUID" -ne 0 ]; then
        msg_err "Please run as root."
        exit 1
    fi
}

function check_dependencies() {
    local deps=("sqlite3" "jq" "curl")
    local install_needed=false

    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            msg_warn "$dep not found. Installing..."
            install_needed=true
        fi
    done

    if [ "$install_needed" = true ]; then
        apt-get update -qq
        apt-get install -y sqlite3 jq curl -qq
        msg_ok "Dependencies installed."
    fi
    
    mkdir -p "$TEMP_DIR"
    mkdir -p "$BACKUP_DIR"
}

function find_database() {
    if [ -f "$DEFAULT_DB_PATH" ]; then
        DB_PATH="$DEFAULT_DB_PATH"
    else
        msg_info "Searching for x-ui.db files..."
        mapfile -t FOUND_DBS < <(find /etc /usr /home /root -name "x-ui.db" -type f 2>/dev/null | head -n 5)

        if [ ${#FOUND_DBS[@]} -eq 0 ]; then
            msg_err "No databases found automatically."
            echo -e "Please enter the full path to x-ui.db: \c"
            read -r USER_PATH
            if [ -f "$USER_PATH" ]; then
                DB_PATH="$USER_PATH"
            else
                msg_err "File not found. Exiting."
                exit 1
            fi
        else
            echo -e "${CYAN}Found the following databases:${NC}"
            local i=1
            for db in "${FOUND_DBS[@]}"; do
                echo -e "[$i] $db"
                ((i++))
            done
            echo -e "Select a number: \c"
            read -r db_choice
            if [[ "$db_choice" -ge 1 && "$db_choice" -le "${#FOUND_DBS[@]}" ]]; then
                DB_PATH="${FOUND_DBS[$((db_choice-1))]}"
            else
                DB_PATH="${FOUND_DBS[0]}"
            fi
        fi
    fi
    # Verify DB is readable
    if ! sqlite3 "$DB_PATH" "PRAGMA integrity_check;" >/dev/null 2>&1; then
        msg_err "Selected database is corrupted or not a valid SQLite file: $DB_PATH"
        exit 1
    fi
}

function create_backup() {
    local label=$1
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="x-ui.db.${label}.${timestamp}.bak"
    local backup_path="$BACKUP_DIR/$backup_name"

    msg_info "Creating backup: $backup_name"
    # Use sqlite3 backup API for safer hot backup
    sqlite3 "$DB_PATH" ".backup '$backup_path'"
    if [ $? -eq 0 ]; then
        msg_ok "Backup success."
    else
        msg_err "Failed to create backup! Aborting."
        exit 1
    fi
}

function select_inbounds() {
    echo -e "\n${YELLOW}Available Inbounds:${NC}"
    printf "${BOLD}%-5s %-20s %-10s %-10s${NC}\n" "ID" "Remark" "Port" "Protocol"
    echo "--------------------------------------------------------"
    
    sqlite3 -separator $'\t' "$DB_PATH" "SELECT id, remark, port, protocol FROM inbounds" | while read -r id remark port proto; do
        printf "%-5s %-20s %-10s %-10s\n" "$id" "$remark" "$port" "$proto"
    done
    echo "--------------------------------------------------------"
    echo -e "Enter IDs (e.g. ${CYAN}1,3${NC}), '${BOLD}all${NC}', or '${BOLD}0${NC}' to Back: \c"
    read -r input_str

    TARGET_IDS=""
    
    if [[ "$input_str" == "0" ]]; then
        return 1
    fi

    if [[ "$input_str" == "all" ]]; then
        TARGET_IDS=$(sqlite3 "$DB_PATH" "SELECT id FROM inbounds;")
        msg_info "Selected ALL inbounds."
    else
        # Replace commas with spaces
        local formatted_ids=$(echo "$input_str" | tr ',' ' ')
        for id in $formatted_ids; do
            # Validate ID exists
            local exists=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM inbounds WHERE id='$id';")
            if [ "$exists" -eq "1" ]; then
                TARGET_IDS="$TARGET_IDS $id"
            else
                msg_warn "Inbound ID $id not found, skipping."
            fi
        done
    fi

    if [ -z "$TARGET_IDS" ]; then
        msg_err "No valid Inbounds selected."
        return 1
    fi
    return 0
}

function apply_sql_safely() {
    local sql_file=$1
    
    msg_info "Stopping x-ui to prevent database locks..."
    systemctl stop x-ui
    
    msg_info "Applying database changes..."
    # Add busy timeout and use transaction
    sqlite3 "$DB_PATH" "PRAGMA busy_timeout=5000;" ".read $sql_file"
    
    msg_info "Restarting x-ui..."
    systemctl start x-ui
    msg_ok "Service restarted."
}

# --- JOB 1: Remove Clients by Regex ---
function job_remove_regex() {
    print_banner
    echo -e "${MAGENTA}>> Option: Remove Clients via Regex${NC}"
    
    if ! select_inbounds; then return; fi

    echo -e "\nSelect target field:"
    echo "1) Email"
    echo "2) UUID / ID"
    echo "3) SubID"
    echo "0) Back"
    echo -e "Choice [1]: \c"
    read -r target_choice
    
    if [ "$target_choice" == "0" ]; then return; fi

    local json_field
    case "$target_choice" in
        2) json_field="id" ;;
        3) json_field="subId" ;;
        *) json_field="email" ;;
    esac

    echo -e "\n${BOLD}Regex Quick Guide:${NC}"
    echo -e "  ${CYAN}^5[0-9]{3}$${NC} -> Range 5000 to 5999 (exact match)"
    echo -e "  ${CYAN}50299${NC}      -> Specific User (contains 50299)"
    echo -e "  ${CYAN}^test.*${NC}    -> Starts with 'test'"
    echo -e "Enter Regex Pattern (or ${BOLD}0${NC} to Back): \c"
    read -r regex_pattern

    if [[ "$regex_pattern" == "0" || -z "$regex_pattern" ]]; then
        return
    fi

    # -- SCAN PHASE --
    msg_info "Scanning database for matches..."
    local found_matches=0
    local match_file="$TEMP_DIR/regex_matches.txt"
    local sql_file="$TEMP_DIR/update.sql"
    
    rm -f "$sql_file" "$match_file"

    # Start Transaction for speed and safety
    echo "BEGIN TRANSACTION;" > "$sql_file"

    for iid in $TARGET_IDS; do
        settings=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id=$iid;")
        remark=$(sqlite3 "$DB_PATH" "SELECT remark FROM inbounds WHERE id=$iid;")
        
        if echo "$settings" | jq -e '.clients' >/dev/null 2>&1; then
            deleted_items=$(echo "$settings" | jq -r ".clients[] | select(.$json_field | test(\"$regex_pattern\")) | .email")
            
            if [ ! -z "$deleted_items" ]; then
                echo -e "\n${BOLD}Inbound $iid ($remark):${NC}" >> "$match_file"
                echo "$deleted_items" | sed 's/^/  - /' >> "$match_file"
                
                count=$(echo "$deleted_items" | wc -l)
                found_matches=$((found_matches + count))

                # Update JSON
                echo "$settings" | jq "del(.clients[] | select(.$json_field | test(\"$regex_pattern\")))" > "$TEMP_DIR/new_settings_$iid.json"
                
                echo "UPDATE inbounds SET settings='" >> "$sql_file"
                cat "$TEMP_DIR/new_settings_$iid.json" | sed "s/'/''/g" >> "$sql_file"
                echo "' WHERE id=$iid;" >> "$sql_file"
                
                for email in $deleted_items; do
                    echo "DELETE FROM client_traffics WHERE email='$email';" >> "$sql_file"
                done
            fi
        fi
    done
    
    echo "COMMIT;" >> "$sql_file"

    if [ $found_matches -eq 0 ]; then
        msg_warn "No clients found matching that regex."
        read -p "Press Enter to return..."
        return
    fi

    echo -e "\n${YELLOW}Scan Complete. Found $found_matches matches.${NC}"
    echo -e "Do you want to see the list of matched clients? [Y/n]: \c"
    read -r show_list
    show_list=${show_list:-y}
    
    if [[ "$show_list" =~ ^[Yy]$ ]]; then
        echo -e "\n--- MATCH PREVIEW ---"
        cat "$match_file"
        echo -e "---------------------"
    fi

    echo -e "\n${RED}${BOLD}Confirm deletion of these $found_matches clients? [y/N] (n to Cancel): \c${NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        create_backup "regex_remove"
        apply_sql_safely "$sql_file"
    else
        msg_info "Operation cancelled."
    fi
    read -p "Press Enter..."
}

# --- JOB 2: Remove Clients by Date ---
function job_remove_date() {
    print_banner
    echo -e "${MAGENTA}>> Option: Remove Clients via Expiry Date${NC}"

    if ! select_inbounds; then return; fi

    echo -e "\nEnter Timezone (e.g. Asia/Tehran). Default UTC:"
    echo -e "Input (or ${BOLD}0${NC} to Back): \c"
    read -r user_tz
    if [ "$user_tz" == "0" ]; then return; fi
    user_tz=${user_tz:-UTC}

    echo -e "\n1) Remove expired BEFORE date (Cleanup)"
    echo "2) Remove expiring AFTER date"
    echo "0) Back"
    echo -e "Choice [1]: \c"
    read -r mode_choice
    if [ "$mode_choice" == "0" ]; then return; fi

    echo -e "\nEnter Date (YYYY-MM-DD HH:MM:SS) (or ${BOLD}0${NC} to Back): \c"
    read -r date_str
    if [ "$date_str" == "0" ]; then return; fi

    if ! err_msg=$(TZ="$user_tz" date -d "$date_str" 2>&1 >/dev/null); then
        msg_err "Invalid Date!"
        echo -e "${RED}System Error:${NC} $err_msg"
        read -p "Press Enter to return..."
        return
    fi

    target_ts=$(TZ="$user_tz" date -d "$date_str" +%s%3N 2>/dev/null)
    if [ -z "$target_ts" ]; then
        msg_err "Date conversion failed."
        return
    fi

    msg_info "Scanning database for matches..."
    local found_matches=0
    local match_file="$TEMP_DIR/date_matches.txt"
    local sql_file="$TEMP_DIR/update.sql"
    rm -f "$sql_file" "$match_file"

    echo "BEGIN TRANSACTION;" > "$sql_file"

    local jq_filter=""
    if [ "$mode_choice" == "2" ]; then
        jq_filter="select(.expiryTime > 0 and .expiryTime > $target_ts)"
    else
        jq_filter="select(.expiryTime > 0 and .expiryTime < $target_ts)"
    fi

    for iid in $TARGET_IDS; do
        settings=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id=$iid;")
        remark=$(sqlite3 "$DB_PATH" "SELECT remark FROM inbounds WHERE id=$iid;")
        
        if echo "$settings" | jq -e '.clients' >/dev/null 2>&1; then
            deleted_items=$(echo "$settings" | jq -r ".clients[] | $jq_filter | .email")
            
            if [ ! -z "$deleted_items" ]; then
                echo -e "\n${BOLD}Inbound $iid ($remark):${NC}" >> "$match_file"
                echo "$deleted_items" | sed 's/^/  - /' >> "$match_file"

                count=$(echo "$deleted_items" | wc -l)
                found_matches=$((found_matches + count))
                
                echo "$settings" | jq "del(.clients[] | $jq_filter)" > "$TEMP_DIR/new_settings_$iid.json"
                
                echo "UPDATE inbounds SET settings='" >> "$sql_file"
                cat "$TEMP_DIR/new_settings_$iid.json" | sed "s/'/''/g" >> "$sql_file"
                echo "' WHERE id=$iid;" >> "$sql_file"
                
                for email in $deleted_items; do
                    echo "DELETE FROM client_traffics WHERE email='$email';" >> "$sql_file"
                done
            fi
        fi
    done
    
    echo "COMMIT;" >> "$sql_file"

    if [ $found_matches -eq 0 ]; then
        msg_warn "No clients matched the date criteria."
        read -p "Press Enter to return..."
        return
    fi

    echo -e "\n${YELLOW}Scan Complete. Found $found_matches matches.${NC}"
    echo -e "Do you want to see the list of matched clients? [Y/n]: \c"
    read -r show_list
    show_list=${show_list:-y}

    if [[ "$show_list" =~ ^[Yy]$ ]]; then
        echo -e "\n--- MATCH PREVIEW ---"
        cat "$match_file"
        echo -e "---------------------"
    fi

    echo -e "\n${RED}${BOLD}Confirm deletion of these $found_matches clients? [y/N] (n to Cancel): \c${NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        create_backup "date_cleanup"
        apply_sql_safely "$sql_file"
    else
        msg_info "Operation cancelled."
    fi
    read -p "Press Enter..."
}

# --- JOB 3: Restore Database ---
function job_switch_db() {
    print_banner
    echo -e "${MAGENTA}>> Option: Switch / Restore Database${NC}"
    
    mapfile -t BACKUPS < <(find "$BACKUP_DIR" -name "*.bak" -o -name "*.db" | sort -r | head -n 15)
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        msg_warn "No backups found."
    else
        local i=1
        for b in "${BACKUPS[@]}"; do
            echo -e "[$i] $(basename "$b")"
            ((i++))
        done
        echo -e "Select file (or 'c' for custom, '0' to Back): \c"
        read -r b_choice
        if [ "$b_choice" == "0" ]; then return; fi

        if [[ "$b_choice" == "c" ]]; then
             echo -e "Enter full path: \c"
             read -r TARGET_RESTORE
        elif [[ "$b_choice" -ge 1 && "$b_choice" -le "${#BACKUPS[@]}" ]]; then
            TARGET_RESTORE="${BACKUPS[$((b_choice-1))]}"
        else
            return
        fi

        if [ ! -f "$TARGET_RESTORE" ]; then
            msg_err "File not found."
            return
        fi

        echo -e "${RED}Overwrite active database with $(basename "$TARGET_RESTORE")? [y/N]: \c${NC}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            msg_info "Stopping x-ui..."
            systemctl stop x-ui
            cp "$DB_PATH" "${DB_PATH}.pre_restore_safety"
            cp "$TARGET_RESTORE" "$DB_PATH"
            chown root:root "$DB_PATH"
            chmod 644 "$DB_PATH"
            systemctl start x-ui
            msg_ok "Restored & Restarted."
        fi
    fi
    read -p "Press Enter..."
}

# --- JOB 4: Reset Traffic ---
function job_reset_traffic() {
    print_banner
    echo -e "${MAGENTA}>> Option: Reset Traffic Stats${NC}"
    echo "1) Reset ALL clients"
    echo "2) Reset specific email (Regex)"
    echo "0) Back"
    echo -e "Choice: \c"
    read -r t_choice

    if [ "$t_choice" == "0" ]; then return; fi

    if [ "$t_choice" == "1" ]; then
        create_backup "reset_all_traffic"
        msg_info "Stopping x-ui..."
        systemctl stop x-ui
        sqlite3 "$DB_PATH" "UPDATE client_traffics SET up=0, down=0, total=0;"
        sqlite3 "$DB_PATH" "UPDATE inbounds SET up=0, down=0;"
        systemctl start x-ui
        msg_ok "All traffic stats reset."
    elif [ "$t_choice" == "2" ]; then
        echo -e "Enter Email/Regex (0 to Back): \c"
        read -r pattern
        if [ "$pattern" == "0" ]; then return; fi
        
        count=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM client_traffics WHERE email LIKE '%$pattern%';")
        if [ "$count" -gt 0 ]; then
            create_backup "reset_traffic_$pattern"
            msg_info "Stopping x-ui..."
            systemctl stop x-ui
            sqlite3 "$DB_PATH" "UPDATE client_traffics SET up=0, down=0 WHERE email LIKE '%$pattern%';"
            systemctl start x-ui
            msg_ok "Reset traffic for $count clients."
        else
            msg_warn "No clients found matching '$pattern'."
        fi
    fi
    read -p "Press Enter..."
}

# --- JOB 6: Manage Backups ---
function job_manage_backups() {
    while true; do
        print_banner
        echo -e "${MAGENTA}>> Option: Manage / Delete Backups${NC}"
        mapfile -t BACKUPS < <(find "$BACKUP_DIR" -name "*.bak" | sort -r)

        if [ ${#BACKUPS[@]} -eq 0 ]; then
            msg_warn "No backups found in $BACKUP_DIR"
            read -p "Press Enter to return..."
            return
        fi

        local i=1
        for b in "${BACKUPS[@]}"; do
            echo -e "[$i] $(basename "$b")   $(du -h "$b" | cut -f1)"
            ((i++))
        done
        
        echo "d) Delete ALL backups"
        echo "0) Back"
        echo -e "Select number to DELETE: \c"
        read -r del_choice

        if [ "$del_choice" == "0" ]; then return; fi

        if [ "$del_choice" == "d" ]; then
            echo -e "${RED}Are you sure you want to delete ALL backups? [y/N]: \c${NC}"
            read -r conf
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                rm -rf "${BACKUP_DIR:?}/"*
                msg_ok "All backups deleted."
            fi
        elif [[ "$del_choice" -ge 1 && "$del_choice" -le "${#BACKUPS[@]}" ]]; then
            file_to_del="${BACKUPS[$((del_choice-1))]}"
            rm "$file_to_del"
            msg_ok "Deleted: $(basename "$file_to_del")"
            sleep 1
        else
            msg_warn "Invalid selection."
            sleep 1
        fi
    done
}

# --- JOB 5: Vacuum ---
function job_optimize() {
    msg_info "Stopping x-ui..."
    systemctl stop x-ui
    msg_info "Optimizing (Vacuum)..."
    sqlite3 "$DB_PATH" "VACUUM;"
    systemctl start x-ui
    msg_ok "Done."
    read -p "Press Enter..."
}

# --- Main Menu ---
check_root
check_dependencies
find_database

while true; do
    print_banner
    echo -e "${BOLD}DB:${NC} $DB_PATH"
    echo "----------------------------------------------------"
    echo -e "1) ${RED}Remove Clients (Regex)${NC}"
    echo -e "2) ${RED}Remove Clients (Date)${NC}"
    echo -e "3) ${YELLOW}Restore Database${NC}"
    echo -e "4) ${BLUE}Reset Traffic${NC}"
    echo -e "5) ${GREEN}Optimize (Vacuum)${NC}"
    echo -e "6) ${CYAN}Manage / Delete Backups${NC}"
    echo -e "0) Exit"
    echo "----------------------------------------------------"
    echo -e "Select: \c"
    read -r choice

    case $choice in
        1) job_remove_regex ;;
        2) job_remove_date ;;
        3) job_switch_db ;;
        4) job_reset_traffic ;;
        5) job_optimize ;;
        6) job_manage_backups ;;
        0) rm -rf "$TEMP_DIR"; exit 0 ;;
        *) msg_err "Invalid option." ; sleep 1 ;;
    esac
done
