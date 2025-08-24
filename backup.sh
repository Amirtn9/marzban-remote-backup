#!/bin/bash

# Marzban Remote Backup Manager (MRBM)-AmirTN
# Core script for managing backups.

# Set strict mode for robustness
set -e
set -o pipefail

# --- Configuration ---
CONFIG_FILE="config.env"
BACKUP_DIR="backups"
LOG_FILE="backup.log"
RETENTION_DAYS=7

# --- Functions ---

# Load and save server configurations
load_config() {
    declare -gA SERVERS
    if [[ -f "$CONFIG_FILE" ]]; then
        if [[ $(stat -c "%a" "$CONFIG_FILE") -ne 600 ]]; then
            echo "Warning: Changing permissions of $CONFIG_FILE to 600 for security."
            chmod 600 "$CONFIG_FILE"
        fi
        while IFS='=' read -r key value; do
            if [[ $key =~ ^SERVERS\[(.+)\]$ ]]; then
                local server_name="${BASH_REMATCH[1]}"
                SERVERS[$server_name]="$value"
            elif [[ $key =~ ^LAST_BACKUP_(.+) ]]; then
                local server_name="${BASH_REMATCH[1]}"
                declare -g LAST_BACKUP_"$server_name"="$value"
            fi
        done < <(grep -v '^\s*#\|^\s*$' "$CONFIG_FILE")
    fi
}

save_config() {
    echo "# MRBM Configuration File" > "$CONFIG_FILE.tmp"
    for key in "${!SERVERS[@]}"; do
        echo "SERVERS[\"$key\"]=\"${SERVERS[$key]}\"" >> "$CONFIG_FILE.tmp"
    done
    
    for var_name in "${!LAST_BACKUP_@}"; do
        echo "$var_name=\"${!var_name}\"" >> "$CONFIG_FILE.tmp"
    done
    
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "Configuration saved."
}

# Add a new server
add_server() {
    read -p "Enter a unique server name: " server_name
    if [[ -n "${SERVERS[$server_name]}" ]]; then
        echo "Error: A server with this name already exists."
        return
    fi
    
    echo "--- Server Details ---"
    read -p "IP or domain: " ip
    read -p "SSH Port (default 22): " port
    port=${port:-22}
    read -p "SSH Username (default root): " username
    username=${username:-root}
    
    echo "Warning: Using a password is not secure. Use an SSH key if possible."
    read -s -p "SSH Password (leave blank for key): " password
    echo
    if [[ -z "$password" ]]; then
        read -p "Path to SSH key: " ssh_key
    fi
    
    read -p "Marzban installation path (e.g., /opt/marzban): " marzban_path
    read -p "MySQL/MariaDB container name: " db_container
    read -s -p "MySQL root password: " db_password
    echo
    
    echo "--- Telegram Details ---"
    read -p "Telegram Bot Token: " bot_token
    read -p "Telegram Chat ID: " chat_id

    local data="$ip|$port|$username|$password|$ssh_key|$marzban_path|$db_container|$db_password|$bot_token|$chat_id"
    SERVERS[$server_name]="$data"
    save_config
    echo "Server '$server_name' added successfully."
}

# Manage servers (list and delete)
manage_servers() {
    if [[ ${#SERVERS[@]} -eq 0 ]]; then
        echo "No servers registered."
        return
    fi

    echo "Registered Servers:"
    local i=1
    for name in "${!SERVERS[@]}"; do
        echo "  $i. $name"
        i=$((i+1))
    done
    
    echo "---"
    read -p "Enter the number of the server to delete, or 'q' to go back: " choice
    if [[ "$choice" == "q" ]]; then
        return
    fi
    
    local keys=("${!SERVERS[@]}")
    local server_to_delete="${keys[choice-1]}"
    
    if [[ -n "$server_to_delete" ]]; then
        read -p "Are you sure you want to delete '$server_to_delete'? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            unset SERVERS[$server_to_delete]
            save_config
            echo "Server '$server_to_delete' deleted."
        else
            echo "Deletion canceled."
        fi
    else
        echo "Invalid choice."
    fi
}

# Perform the backup for a single server
perform_backup() {
    local server_name="$1"
    local data="${SERVERS[$server_name]}"
    IFS='|' read -r ip port username password ssh_key marzban_path db_container db_password bot_token chat_id <<< "$data"

    local current_timestamp=$(date +%Y%m%d_%H%M%S)
    local server_backup_dir="$BACKUP_DIR/$server_name"
    mkdir -p "$server_backup_dir"

    echo "$(date): Starting backup for '$server_name'..." | tee -a "$LOG_FILE"
    
    local ssh_cmd
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="ssh -i \"$ssh_key\" -p \"$port\" \"$username@$ip\""
    else
        ssh_cmd="sshpass -p '$password' ssh -p \"$port\" \"$username@$ip\""
    fi

    local final_archive_file="$server_backup_dir/complete-backup-$current_timestamp.tar.gz"
    
    # Use a single, more efficient pipeline
    echo "  - Creating backup archive..." | tee -a "$LOG_FILE"
    if ! eval "$ssh_cmd \"sudo tar -czf - '$marzban_path' | cat - <(sudo docker exec $db_container mysqldump -u root -p'$db_password' --all-databases --single-transaction)\" > \"$final_archive_file\""; then
        echo "Error: Failed to create the final archive." | tee -a "$LOG_FILE"
        return 1
    fi
    
    # Clean up old backups
    echo "  - Cleaning up backups older than $RETENTION_DAYS days..." | tee -a "$LOG_FILE"
    find "$server_backup_dir" -type f -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete
    
    # Send to Telegram
    echo "  - Sending backup to Telegram..." | tee -a "$LOG_FILE"
    if ! curl -s -o /dev/null -w "%{http_code}" -F chat_id="$chat_id" -F document=@"$final_archive_file" "https://api.telegram.org/bot$bot_token/sendDocument" | grep -q "200"; then
        echo "Warning: Failed to send backup to Telegram. Check your bot token and chat ID." | tee -a "$LOG_FILE"
    fi
    
    # Update last backup timestamp
    declare -g LAST_BACKUP_"$server_name"="$current_timestamp"
    save_config
    echo "$(date): Backup for '$server_name' completed and sent successfully." | tee -a "$LOG_FILE"
}

# Setup Cron Job
setup_cron() {
    echo "Select backup interval:"
    echo "1. Every 30 minutes"
    echo "2. Every 1 hour"
    echo "3. Every 6 hours"
    echo "4. Every 12 hours"
    echo "5. Every 24 hours"
    read -p "Choose an option: " choice

    local cron_schedule
    case "$choice" in
        1) cron_schedule="*/30 * * * *" ;;
        2) cron_schedule="0 * * * *" ;;
        3) cron_schedule="0 */6 * * *" ;;
        4) cron_schedule="0 */12 * * *" ;;
        5) cron_schedule="0 0 * * *" ;;
        *) echo "Invalid option." ; return ;;
    esac

    local script_path="$(pwd)/mrbm.sh"
    local cron_command="$cron_schedule $script_path --all"
    
    (crontab -l 2>/dev/null | grep -v "$script_path" || true; echo "$cron_command") | crontab -
    echo "Cron job scheduled for all servers."
    echo "Command: $cron_command"
}

# View status and last backup dates
view_status() {
    if [[ ${#SERVERS[@]} -eq 0 ]]; then
        echo "No servers registered."
        return
    fi
    
    echo "--- Server Status ---"
    for name in "${!SERVERS[@]}"; do
        local last_backup_var="LAST_BACKUP_$name"
        local last_backup="${!last_backup_var}"
        if [[ -n "$last_backup" ]]; then
            echo "  - $name: Last backup on $(date -d "$last_backup" +"%Y-%m-%d %H:%M:%S")"
        else
            echo "  - $name: No backup recorded yet."
        fi
    done
    
    echo "---"
    echo "To view all backups, check the '$BACKUP_DIR' directory."
    echo "To view logs, run: tail $LOG_FILE"
}

# Main Menu and Script Execution
main_menu() {
    while true; do
        clear
        echo "--- Marzban Remote Backup Manager (MRBM) ---"
        echo "1. Add a new server"
        echo "2. Manage existing servers"
        echo "3. Setup backup schedule (Cron Job)"
        echo "4. View backup status"
        echo "5. Exit"
        echo "---"
        read -p "Enter your choice: " choice
        
        case "$choice" in
            1) add_server ;;
            2) manage_servers ;;
            3) setup_cron ;;
            4) view_status ;;
            5) echo "Exiting. Goodbye!"; exit 0 ;;
            *) echo "Invalid option. Please try again." ;;
        esac
        
        read -p "Press Enter to continue..."
    done
}

if [[ "$1" == "--all" ]]; then
    load_config
    if [[ ${#SERVERS[@]} -eq 0 ]]; then
        echo "No servers configured. Exiting."
        exit 1
    fi
    for server_name in "${!SERVERS[@]}"; do
        perform_backup "$server_name"
    done
    exit 0
fi

# Initial setup and main loop
load_config
