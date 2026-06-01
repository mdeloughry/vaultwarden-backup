#!/usr/bin/env python3
# vw-tui.py — Text User Interface for Vaultwarden backup management
#
# Usage: sudo python3 vw-tui.py
#
# Requires: python3, curses, restic, docker, sqlite3
# Configuration: /etc/vaultwarden-backup/backup.env

import os
import sys
import curses
import subprocess
import re
import json
import datetime
import threading
from collections import deque

# ──────────────── Configuration & Paths ────────────────

ENV_FILE = os.environ.get('VW_BACKUP_ENV', '/etc/vaultwarden-backup/backup.env')
RESTIC_PW_FILE = '/etc/vaultwarden-backup/restic-pw'

# Global background caches
snapshot_cache = {}
loading_status = {}  # "None", "Loading", "Success", "Error"
spinner_frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

# ──────────────── Environment Parsing ────────────────

def load_env(file_path):
    env = {}
    if not os.path.exists(file_path):
        return env
    try:
        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    key, val = line.split('=', 1)
                    key = key.strip()
                    val = val.strip()
                    # Remove surrounding quotes
                    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                        val = val[1:-1]
                    env[key] = val
    except Exception:
        pass
    return env

def get_repo_env(repo_type, config):
    """Returns (repo_uri, env_dict) for running restic commands."""
    env = os.environ.copy()
    pw_file = config.get('RESTIC_PASSWORD_FILE', RESTIC_PW_FILE)
    env['RESTIC_PASSWORD_FILE'] = pw_file
    
    if repo_type == 'local':
        repo = config.get('RESTIC_REPO_LOCAL')
    elif repo_type == 'b2':
        repo = config.get('RESTIC_REPO_B2')
        if config.get('B2_ACCOUNT_ID'):
            env['B2_ACCOUNT_ID'] = config.get('B2_ACCOUNT_ID')
        if config.get('B2_ACCOUNT_KEY'):
            env['B2_ACCOUNT_KEY'] = config.get('B2_ACCOUNT_KEY')
    elif repo_type == 'r2':
        repo = config.get('RESTIC_REPO_R2')
        if config.get('AWS_ACCESS_KEY_ID'):
            env['AWS_ACCESS_KEY_ID'] = config.get('AWS_ACCESS_KEY_ID')
        if config.get('AWS_SECRET_ACCESS_KEY'):
            env['AWS_SECRET_ACCESS_KEY'] = config.get('AWS_SECRET_ACCESS_KEY')
    else:
        repo = None
        
    return repo, env

def is_repo_configured(repo_type, config):
    if repo_type == 'local':
        return bool(config.get('RESTIC_REPO_LOCAL'))
    elif repo_type == 'b2':
        return bool(config.get('RESTIC_REPO_B2') and config.get('B2_ACCOUNT_ID') and config.get('B2_ACCOUNT_KEY'))
    elif repo_type == 'r2':
        return bool(config.get('RESTIC_REPO_R2') and config.get('AWS_ACCESS_KEY_ID') and config.get('AWS_SECRET_ACCESS_KEY'))
    return False

# ──────────────── Async Snapshot Loading ────────────────

def async_fetch_snapshots(repo_type, config, force=False):
    if not is_repo_configured(repo_type, config):
        loading_status[repo_type] = "Not Configured"
        return
        
    if loading_status.get(repo_type) == "Loading" and not force:
        return
        
    loading_status[repo_type] = "Loading"
    repo_uri, env = get_repo_env(repo_type, config)
    
    def worker():
        cmd = ['restic', '-r', repo_uri, 'snapshots', '--json']
        try:
            res = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)
            if res.returncode == 0:
                try:
                    snapshots = json.loads(res.stdout)
                    # Sort snapshots by time descending (latest first)
                    snapshots.sort(key=lambda x: x.get('time', ''), reverse=True)
                    snapshot_cache[repo_type] = snapshots
                    loading_status[repo_type] = "Success"
                except Exception as je:
                    snapshot_cache[repo_type] = f"JSON parse error: {str(je)}"
                    loading_status[repo_type] = "Error"
            else:
                err_msg = res.stderr.strip()
                if "config file" in err_msg or "unable to open" in err_msg:
                    snapshot_cache[repo_type] = "Repository is uninitialized. Press [I] to initialize."
                else:
                    snapshot_cache[repo_type] = f"Restic failed:\n{err_msg}"
                loading_status[repo_type] = "Error"
        except subprocess.TimeoutExpired:
            snapshot_cache[repo_type] = "Connection timed out."
            loading_status[repo_type] = "Error"
        except Exception as e:
            snapshot_cache[repo_type] = f"Exception: {str(e)}"
            loading_status[repo_type] = "Error"
            
    threading.Thread(target=worker, daemon=True).start()

# ──────────────── Utility Functions ────────────────

def find_script(name):
    # Check /usr/local/bin first
    usr_bin_path = os.path.join('/usr/local/bin', name)
    if os.path.exists(usr_bin_path):
        return usr_bin_path
    # Check local repository scripts dir relative to this script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    local_path = os.path.join(script_dir, name)
    if os.path.exists(local_path):
        return local_path
    # Check parent scripts folder
    parent_path = os.path.join(os.path.dirname(script_dir), 'scripts', name)
    if os.path.exists(parent_path):
        return parent_path
    return None

def format_time(iso_str):
    try:
        # Parse 2026-05-22T10:00:00.123456Z or 2026-05-22T10:00:00Z
        iso_str = iso_str.split('.')[0].rstrip('Z')
        dt = datetime.datetime.strptime(iso_str, "%Y-%m-%dT%H:%M:%S")
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return iso_str[:19]

def read_last_lines(file_path, limit=500):
    if not os.path.exists(file_path):
        return [f"Log file not found at {file_path}"]
    try:
        with open(file_path, 'r', errors='replace') as f:
            return [line.rstrip() for line in list(deque(f, limit))]
    except Exception as e:
        return [f"Error reading log file: {str(e)}"]

def get_systemd_status(timer_name):
    try:
        res_active = subprocess.run(['systemctl', 'is-active', timer_name], capture_output=True, text=True)
        active = res_active.stdout.strip()
        res_enabled = subprocess.run(['systemctl', 'is-enabled', timer_name], capture_output=True, text=True)
        enabled = res_enabled.stdout.strip()
        return active, enabled
    except Exception:
        return "not installed", "not installed"

def run_interactive_command(stdscr, cmd, env=None):
    """Suspends curses, runs command in foreground, and resumes curses."""
    curses.def_shell_mode()
    curses.endwin()
    print("\n" + "═"*80)
    print(f"Executing: {' '.join(cmd)}")
    print("═"*80 + "\n")
    try:
        subprocess.run(cmd, env=env)
    except KeyboardInterrupt:
        print("\nCommand interrupted by user.")
    except Exception as e:
        print(f"\nError running command: {e}")
    print("\n" + "═"*80)
    input("Press ENTER to return to Vaultwarden TUI...")
    stdscr.reset_shell_mode()
    stdscr.clear()
    stdscr.refresh()

# ──────────────── UI Drawing Helpers ────────────────

def draw_box(stdscr, y, x, h, w, title=None, double=True, color_pair=0):
    if double:
        tl, tr, bl, br, h_line, v_line = '╔', '╗', '╚', '╝', '═', '║'
    else:
        tl, tr, bl, br, h_line, v_line = '┌', '┐', '└', '┘', '─', '│'
        
    stdscr.attron(curses.color_pair(color_pair))
    # Draw horizontal borders
    stdscr.addstr(y, x, tl + h_line * (w - 2) + tr)
    stdscr.addstr(y + h - 1, x, bl + h_line * (w - 2) + br)
    # Draw vertical borders
    for i in range(1, h - 1):
        stdscr.addstr(y + i, x, v_line)
        stdscr.addstr(y + i, x + w - 1, v_line)
        
    if title:
        title = f" {title} "
        if len(title) > w - 4:
            title = title[:w - 7] + "... "
        title_x = x + (w - len(title)) // 2
        stdscr.addstr(y, title_x, title, curses.A_BOLD | curses.color_pair(color_pair))
    stdscr.attroff(curses.color_pair(color_pair))

# ──────────────── Main TUI Loop ────────────────

def main(stdscr):
    # Setup curses settings
    curses.curs_set(0)  # Hide cursor
    stdscr.timeout(200) # Key timeout in milliseconds (non-blocking loop)
    
    # Initialize colors
    if curses.has_colors():
        curses.start_color()
        curses.init_pair(1, curses.COLOR_CYAN, curses.COLOR_BLACK)     # Headers / borders
        curses.init_pair(2, curses.COLOR_GREEN, curses.COLOR_BLACK)    # Active / Healthy
        curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLACK)   # Warning / Highlight
        curses.init_pair(4, curses.COLOR_RED, curses.COLOR_BLACK)      # Error / Critical
        curses.init_pair(5, curses.COLOR_WHITE, curses.COLOR_BLUE)     # Selected Tab header
        curses.init_pair(6, curses.COLOR_WHITE, curses.COLOR_BLACK)    # Plain text
        curses.init_pair(7, curses.COLOR_BLACK, curses.COLOR_CYAN)     # Reverse highlight
        curses.init_pair(8, curses.COLOR_CYAN, curses.COLOR_BLUE)      # Hotkey highlights
        
    # Loaded config data
    config = load_env(ENV_FILE)
    
    # Trigger initial snapshot lists load in background threads
    for rtype in ['local', 'b2', 'r2']:
        if is_repo_configured(rtype, config):
            async_fetch_snapshots(rtype, config)
            
    # TUI State variables
    active_tab = 0  # 0: Dashboard, 1: Snapshots, 2: Logs, 3: Config
    tick_count = 0
    
    # Repos and Snapshots navigation state
    repos = ['local', 'b2', 'r2']
    selected_repo_idx = 0
    selected_snapshot_idx = 0
    snapshot_scroll_offset = 0
    
    # Logs navigation state
    log_files = [
        ('Backup Log', os.environ.get('VW_BACKUP_LOG', '/var/log/vw-backup.log')),
        ('Integrity Check Log', os.environ.get('VW_CHECK_LOG', '/var/log/vw-check.log'))
    ]
    selected_log_idx = 0
    log_scroll_offset = 0
    cached_log_lines = []
    log_file_loaded = None
    
    while True:
        tick_count += 1
        height, width = stdscr.getmaxyx()
        
        # Enforce terminal size constraints
        if width < 80 or height < 24:
            stdscr.clear()
            try:
                stdscr.addstr(0, 0, "Terminal is too small!", curses.color_pair(4) | curses.A_BOLD)
                stdscr.addstr(1, 0, f"Current: {width}x{height}", curses.color_pair(6))
                stdscr.addstr(2, 0, "Required: 80x24 minimum. Please resize your window.", curses.color_pair(3))
            except curses.error:
                pass
            stdscr.refresh()
            # Wait for resize key
            ch = stdscr.getch()
            if ch == ord('q') or ch == ord('Q') or ch == 27:
                break
            continue
            
        stdscr.erase()
        
        # ──────────────── Title Header ────────────────
        draw_box(stdscr, 0, 0, 3, width, title="Vaultwarden Backup Manager", double=True, color_pair=1)
        
        # Sudo check
        is_root = os.geteuid() == 0
        if not is_root:
            stdscr.addstr(1, 2, "⚠️ NON-ROOT USER", curses.color_pair(4) | curses.A_BOLD)
        else:
            stdscr.addstr(1, 2, "✓ ROOT SESSION", curses.color_pair(2) | curses.A_BOLD)
            
        # Draw current datetime
        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        stdscr.addstr(1, width - len(now_str) - 2, now_str, curses.color_pair(6))
        
        # ──────────────── Tabs ────────────────
        tabs = [" 1: Dashboard ", " 2: Snapshots & Restore ", " 3: Log Viewer ", " 4: Configuration "]
        tab_start_x = 2
        for idx, tab_name in enumerate(tabs):
            if idx == active_tab:
                stdscr.addstr(3, tab_start_x, tab_name, curses.color_pair(5) | curses.A_BOLD)
            else:
                stdscr.addstr(3, tab_start_x, tab_name, curses.color_pair(1))
            tab_start_x += len(tab_name) + 2
            
        # Draw tab separator line
        stdscr.addstr(4, 0, "─" * width, curses.color_pair(1))
        
        # ──────────────── Main Panels ────────────────
        content_y = 5
        content_h = height - 8  # Leave room for bottom help keys
        
        # Draw background panels depending on active tab
        if active_tab == 0:
            # ──────────────── DASHBOARD TAB ────────────────
            draw_box(stdscr, content_y, 0, content_h, width, title="Repository & Daemon Status", double=False, color_pair=1)
            
            # Load systemd timer status
            backup_timer_act, backup_timer_en = get_systemd_status('vw-backup.timer')
            check_timer_act, check_timer_en = get_systemd_status('vw-check.timer')
            
            row = content_y + 2
            
            # Repos status table
            stdscr.addstr(row, 3, "CONFiGURED REPOSITORIES:", curses.color_pair(1) | curses.A_BOLD)
            row += 2
            
            headers = f"{'Destination':<15} {'Status':<15} {'Snapshots':<12} {'Details / Storage Location':<30}"
            stdscr.addstr(row, 5, headers, curses.color_pair(1) | curses.A_UNDERLINE)
            row += 1
            
            for rtype in repos:
                status_str = "Not Configured"
                status_color = 6
                snapshots_count = "-"
                details_str = "-"
                
                if is_repo_configured(rtype, config):
                    details_str = config.get(f'RESTIC_REPO_{rtype.upper()}', '-')
                    # Check cache status
                    lstatus = loading_status.get(rtype, "None")
                    if lstatus == "Loading":
                        status_str = f"Loading {spinner_frames[tick_count % len(spinner_frames)]}"
                        status_color = 3
                    elif lstatus == "Success":
                        status_str = "Active"
                        status_color = 2
                        snapshots_count = str(len(snapshot_cache.get(rtype, [])))
                    elif lstatus == "Error":
                        status_str = "Offline / Uninit"
                        status_color = 4
                    else:
                        status_str = "Checking..."
                        status_color = 3
                        # Trigger loading if not done
                        async_fetch_snapshots(rtype, config)
                else:
                    details_str = "(Not configured in backup.env)"
                    status_color = 6
                    
                line = f"{rtype.upper():<15} "
                stdscr.addstr(row, 5, line, curses.color_pair(6))
                stdscr.addstr(row, 5 + 15, f"{status_str:<15}", curses.color_pair(status_color) | (curses.A_BOLD if status_color != 6 else 0))
                stdscr.addstr(row, 5 + 30, f"{snapshots_count:<12}", curses.color_pair(6))
                stdscr.addstr(row, 5 + 42, f"{details_str[:width-50]:<30}", curses.color_pair(6))
                row += 1
                
            row += 2
            stdscr.addstr(row, 3, "SYSTEMD BACKUP TIMERS:", curses.color_pair(1) | curses.A_BOLD)
            row += 2
            
            # Systemd Timers Section
            def color_timer(status, enabled):
                if status == "active":
                    return 2 # Green
                if status == "inactive":
                    return 3 # Yellow
                return 4 # Red
                
            c_backup = color_timer(backup_timer_act, backup_timer_en)
            c_check = color_timer(check_timer_act, check_timer_en)
            
            stdscr.addstr(row, 5, "vw-backup.timer (Daily 3AM):  ", curses.color_pair(6))
            stdscr.addstr(row, 35, f"{backup_timer_act} ({backup_timer_en})", curses.color_pair(c_backup) | curses.A_BOLD)
            row += 1
            stdscr.addstr(row, 5, "vw-check.timer (Weekly Sun):  ", curses.color_pair(6))
            stdscr.addstr(row, 35, f"{check_timer_act} ({check_timer_en})", curses.color_pair(c_check) | curses.A_BOLD)
            row += 2
            
            # Configuration Quick Info
            stdscr.addstr(row, 3, "QUiCK CONFIG INFO:", curses.color_pair(1) | curses.A_BOLD)
            row += 1
            stdscr.addstr(row, 5, f"Vaultwarden Data (VW_DATA):   {config.get('VW_DATA', 'NOT SET')}", curses.color_pair(6))
            row += 1
            stdscr.addstr(row, 5, f"Healthcheck Ping URL:         {config.get('HEALTHCHECK_URL', 'Disabled')}", curses.color_pair(6))
            row += 1
            stdscr.addstr(row, 5, f"Retention Settings:           Keep Daily: {config.get('KEEP_DAILY', '7')} | Keep Weekly: {config.get('KEEP_WEEKLY', '4')} | Keep Monthly: {config.get('KEEP_MONTHLY', '12')}", curses.color_pair(6))
            
        elif active_tab == 1:
            # ──────────────── SNAPSHOTS & RESTORES TAB ────────────────
            draw_box(stdscr, content_y, 0, content_h, width, title="Snapshot Management", double=False, color_pair=1)
            
            # Draw Repository Select Header
            stdscr.addstr(content_y + 1, 3, "Select Repository: ", curses.color_pair(6) | curses.A_BOLD)
            repo_x = 22
            for idx, rtype in enumerate(repos):
                is_sel = (idx == selected_repo_idx)
                label = f" {rtype.upper()} "
                if is_sel:
                    stdscr.addstr(content_y + 1, repo_x, label, curses.color_pair(7) | curses.A_BOLD)
                else:
                    if is_repo_configured(rtype, config):
                        stdscr.addstr(content_y + 1, repo_x, label, curses.color_pair(2))
                    else:
                        stdscr.addstr(content_y + 1, repo_x, label, curses.color_pair(6))
                repo_x += len(label) + 3
                
            stdscr.addstr(content_y + 2, 2, "─" * (width - 4), curses.color_pair(1))
            
            # Selected Repo Information
            cur_repo = repos[selected_repo_idx]
            lstatus = loading_status.get(cur_repo, "None")
            
            if not is_repo_configured(cur_repo, config):
                stdscr.addstr(content_y + 4, 5, f"Repository '{cur_repo.upper()}' is not configured in backup.env.", curses.color_pair(3) | curses.A_BOLD)
                stdscr.addstr(content_y + 5, 5, "Please configure details on the 'Settings' tab first.", curses.color_pair(6))
            elif lstatus == "Loading":
                spinner = spinner_frames[tick_count % len(spinner_frames)]
                stdscr.addstr(content_y + 5, (width // 2) - 15, f"{spinner} Loading snapshots list from {cur_repo.upper()}...", curses.color_pair(3) | curses.A_BOLD)
            elif lstatus == "Error":
                err_text = snapshot_cache.get(cur_repo, "Unknown error loading snapshots.")
                stdscr.addstr(content_y + 4, 5, "ERROR LOADING SNAPSHOTS:", curses.color_pair(4) | curses.A_BOLD)
                
                # Split and wrap multi-line error
                err_lines = str(err_text).split('\n')
                for line_idx, eline in enumerate(err_lines[:content_h - 8]):
                    stdscr.addstr(content_y + 6 + line_idx, 5, eline[:width - 10], curses.color_pair(4))
            elif lstatus == "Success":
                snapshots = snapshot_cache.get(cur_repo, [])
                if not snapshots:
                    stdscr.addstr(content_y + 5, (width // 2) - 10, "No snapshots found in repository.", curses.color_pair(3) | curses.A_BOLD)
                else:
                    # Draw Snapshots Table
                    row_y = content_y + 3
                    table_h = content_h - 5
                    
                    # Columns: ID (10) | Timestamp (20) | Host (15) | Tags (remaining)
                    header_line = f"  {'Snapshot ID':<12} {'Backup Time (Local)':<22} {'Host':<16} {'Tags':<20}"
                    stdscr.addstr(row_y, 2, header_line[:width-4], curses.color_pair(1) | curses.A_UNDERLINE)
                    row_y += 1
                    
                    # Adjust selection boundaries
                    num_snapshots = len(snapshots)
                    if selected_snapshot_idx >= num_snapshots:
                        selected_snapshot_idx = num_snapshots - 1
                    if selected_snapshot_idx < 0:
                        selected_snapshot_idx = 0
                        
                    # Calculate scrolling window
                    max_visible_rows = table_h - 2
                    if selected_snapshot_idx < snapshot_scroll_offset:
                        snapshot_scroll_offset = selected_snapshot_idx
                    elif selected_snapshot_idx >= snapshot_scroll_offset + max_visible_rows:
                        snapshot_scroll_offset = selected_snapshot_idx - max_visible_rows + 1
                        
                    for i in range(max_visible_rows):
                        snap_idx = snapshot_scroll_offset + i
                        if snap_idx >= num_snapshots:
                            break
                            
                        snap = snapshots[snap_idx]
                        sid = snap.get('short_id', snap.get('id', '--------'))
                        stime = format_time(snap.get('time', ''))
                        shost = snap.get('hostname', 'unknown')
                        stags = ", ".join(snap.get('tags', []))
                        
                        snap_line = f"  {sid:<12} {stime:<22} {shost:<16} {stags:<20}"
                        
                        display_y = row_y + i
                        is_sel = (snap_idx == selected_snapshot_idx)
                        
                        if is_sel:
                            stdscr.addstr(display_y, 2, f"▶ {snap_line[:width-7]}", curses.color_pair(3) | curses.A_BOLD)
                        else:
                            stdscr.addstr(display_y, 2, f"  {snap_line[:width-7]}", curses.color_pair(6))
                            
                    # Show scrolling scroll indicator
                    if num_snapshots > max_visible_rows:
                        scroll_info = f" {selected_snapshot_idx + 1} / {num_snapshots} "
                        stdscr.addstr(content_y + content_h - 2, width - len(scroll_info) - 4, scroll_info, curses.color_pair(1))
            else:
                # Trigger fetch
                async_fetch_snapshots(cur_repo, config)
                
        elif active_tab == 2:
            # ──────────────── LOG VIEWER TAB ────────────────
            draw_box(stdscr, content_y, 0, content_h, width, title="System Logs", double=False, color_pair=1)
            
            # Header log selector
            stdscr.addstr(content_y + 1, 3, "Select Log: ", curses.color_pair(6) | curses.A_BOLD)
            log_x = 16
            for idx, (log_name, log_path) in enumerate(log_files):
                is_sel = (idx == selected_log_idx)
                label = f" {log_name} "
                if is_sel:
                    stdscr.addstr(content_y + 1, log_x, label, curses.color_pair(7) | curses.A_BOLD)
                else:
                    stdscr.addstr(content_y + 1, log_x, label, curses.color_pair(1))
                log_x += len(label) + 4
                
            stdscr.addstr(content_y + 2, 2, "─" * (width - 4), curses.color_pair(1))
            
            cur_log_name, cur_log_path = log_files[selected_log_idx]
            
            # Load log if needed
            if log_file_loaded != cur_log_path:
                cached_log_lines = read_last_lines(cur_log_path, limit=1000)
                log_file_loaded = cur_log_path
                log_scroll_offset = max(0, len(cached_log_lines) - (content_h - 5))
                
            # Render scrolling lines
            log_view_h = content_h - 5
            log_y = content_y + 3
            
            num_lines = len(cached_log_lines)
            if log_scroll_offset > num_lines - log_view_h:
                log_scroll_offset = max(0, num_lines - log_view_h)
            if log_scroll_offset < 0:
                log_scroll_offset = 0
                
            for i in range(log_view_h):
                line_idx = log_scroll_offset + i
                if line_idx >= num_lines:
                    break
                line_content = cached_log_lines[line_idx]
                
                # Check for warnings/errors in logs to colorize
                line_color = 6
                if "ERROR" in line_content or "failed" in line_content or "FAIL" in line_content:
                    line_color = 4
                elif "WARN" in line_content:
                    line_color = 3
                elif "SUCCESS" in line_content or "complete" in line_content:
                    line_color = 2
                    
                stdscr.addstr(log_y + i, 3, line_content[:width - 6], curses.color_pair(line_color))
                
            # Scroll percentage indicator
            if num_lines > log_view_h:
                percent = int((log_scroll_offset + log_view_h) / num_lines * 100)
                scroll_info = f" Lines {log_scroll_offset + 1}-{min(num_lines, log_scroll_offset + log_view_h)} / {num_lines} ({percent}%) "
                stdscr.addstr(content_y + content_h - 2, width - len(scroll_info) - 4, scroll_info, curses.color_pair(1))
            elif num_lines == 0:
                stdscr.addstr(content_y + 4, 5, "Log file is empty.", curses.color_pair(3))
                
        elif active_tab == 3:
            # ──────────────── CONFIGURATION TAB ────────────────
            draw_box(stdscr, content_y, 0, content_h, width, title="Active Configuration (backup.env)", double=False, color_pair=1)
            
            # Display active config path
            stdscr.addstr(content_y + 1, 3, f"Configuration file path: {ENV_FILE}", curses.color_pair(1) | curses.A_BOLD)
            stdscr.addstr(content_y + 2, 2, "─" * (width - 4), curses.color_pair(1))
            
            config_lines = []
            if not os.path.exists(ENV_FILE):
                config_lines = [
                    ("ERROR", "backup.env file does not exist!"),
                    ("ACTION", "Press [S] on the Dashboard to execute the one-time installer scripts,"),
                    ("ACTION", "which will generate the config templates at /etc/vaultwarden-backup/.")
                ]
            else:
                # Load env raw to list lines
                try:
                    with open(ENV_FILE, 'r') as f:
                        for line in f:
                            line_str = line.strip()
                            if not line_str or line_str.startswith('#'):
                                continue
                            if '=' in line_str:
                                k, v = line_str.split('=', 1)
                                config_lines.append((k.strip(), v.strip()))
                except Exception as e:
                    config_lines = [("ERROR", f"Could not read config file: {str(e)}")]
                    
            cfg_y = content_y + 3
            cfg_h = content_h - 5
            
            for idx, item in enumerate(config_lines[:cfg_h]):
                key, val = item
                if key in ["ERROR", "ACTION"]:
                    color = 4 if key == "ERROR" else 3
                    stdscr.addstr(cfg_y + idx, 5, f"{key}: {val}", curses.color_pair(color) | curses.A_BOLD)
                else:
                    stdscr.addstr(cfg_y + idx, 5, f"{key:<28} = ", curses.color_pair(1) | curses.A_BOLD)
                    # Protect credentials from view if needed, or show them
                    display_val = val
                    if any(cred in key.lower() for cred in ['key', 'secret', 'password']):
                        display_val = val[:4] + "*" * (len(val) - 4) if len(val) > 4 else "********"
                    stdscr.addstr(cfg_y + idx, 35, display_val[:width - 40], curses.color_pair(6))
                    
            if os.path.exists(ENV_FILE):
                stdscr.addstr(content_y + content_h - 2, 5, "Press [E] to launch editor (nano) and modify configuration", curses.color_pair(3) | curses.A_BOLD)
                
        # ──────────────── Help & Hotkey Bottom Bar ────────────────
        help_y = height - 3
        draw_box(stdscr, help_y, 0, 3, width, title=None, double=False, color_pair=1)
        
        # General navigation controls
        stdscr.addstr(help_y + 1, 2, "Tab: Switch Tabs | Q: Quit | ", curses.color_pair(6))
        
        # Contextual controls
        if active_tab == 0:
            stdscr.addstr(help_y + 1, 30, "B: Backup | C: Check | S: Setup | E: Edit Env | V/L: Logs", curses.color_pair(3))
        elif active_tab == 1:
            stdscr.addstr(help_y + 1, 30, "◀ / ▶: Change Repo | ▲ / ▼: Move | T: Test Restore | R: Full Restore | I: Init | F: Refresh", curses.color_pair(3))
        elif active_tab == 2:
            stdscr.addstr(help_y + 1, 30, "◀ / ▶: Change Log | ▲ / ▼: Scroll | PgUp/PgDn: Fast | R: Reload", curses.color_pair(3))
        elif active_tab == 3:
            stdscr.addstr(help_y + 1, 30, "E: Edit Env File in editor", curses.color_pair(3))
            
        stdscr.refresh()
        
        # ──────────────── Key Handling ────────────────
        ch = stdscr.getch()
        
        if ch == -1:
            continue  # Timeout occurred
            
        if ch in [ord('q'), ord('Q'), 27]: # 'q', 'Q', Esc
            break
            
        elif ch == 9: # Tab key
            active_tab = (active_tab + 1) % 4
            # Force log reload on entering log tab
            if active_tab == 2:
                log_file_loaded = None
                
        elif ch == ord('1'):
            active_tab = 0
        elif ch == ord('2'):
            active_tab = 1
        elif ch == ord('3'):
            active_tab = 2
            log_file_loaded = None
        elif ch == ord('4'):
            active_tab = 3
            
        # ──────────────── Dashboard Actions ────────────────
        elif active_tab == 0:
            if ch in [ord('b'), ord('B')]:
                script = find_script("vw-backup.sh")
                if script:
                    run_interactive_command(stdscr, ["sudo", script])
                    # Refresh repositories list states
                    for rtype in repos:
                        if is_repo_configured(rtype, config):
                            async_fetch_snapshots(rtype, config, force=True)
                else:
                    run_interactive_command(stdscr, ["echo", "Error: vw-backup.sh script not found."])
            elif ch in [ord('c'), ord('C')]:
                script = find_script("vw-check.sh")
                if script:
                    run_interactive_command(stdscr, ["sudo", script])
                else:
                    run_interactive_command(stdscr, ["echo", "Error: vw-check.sh script not found."])
            elif ch in [ord('s'), ord('S')]:
                script = find_script("vw-setup.sh")
                if script:
                    run_interactive_command(stdscr, ["sudo", script])
                    # Reload configuration after setup
                    config = load_env(ENV_FILE)
                else:
                    run_interactive_command(stdscr, ["echo", "Error: vw-setup.sh script not found."])
            elif ch in [ord('e'), ord('E')]:
                # Suspend curses and edit env config
                editor = os.environ.get('EDITOR', 'nano')
                run_interactive_command(stdscr, ["sudo", editor, ENV_FILE])
                config = load_env(ENV_FILE)
                for rtype in repos:
                    if is_repo_configured(rtype, config):
                        async_fetch_snapshots(rtype, config, force=True)
            elif ch in [ord('v'), ord('V')]:
                # Switch to Log Viewer tab and select backup log
                active_tab = 2
                selected_log_idx = 0
                log_file_loaded = None
            elif ch in [ord('l'), ord('L')]:
                # Switch to Log Viewer tab and select check log
                active_tab = 2
                selected_log_idx = 1
                log_file_loaded = None
                
        # ──────────────── Snapshots Actions ────────────────
        elif active_tab == 1:
            cur_repo = repos[selected_repo_idx]
            lstatus = loading_status.get(cur_repo, "None")
            
            if ch == curses.KEY_LEFT:
                selected_repo_idx = (selected_repo_idx - 1) % len(repos)
                selected_snapshot_idx = 0
                snapshot_scroll_offset = 0
            elif ch == curses.KEY_RIGHT:
                selected_repo_idx = (selected_repo_idx + 1) % len(repos)
                selected_snapshot_idx = 0
                snapshot_scroll_offset = 0
            elif ch == curses.KEY_UP:
                if lstatus == "Success":
                    snapshots = snapshot_cache.get(cur_repo, [])
                    if snapshots:
                        selected_snapshot_idx = (selected_snapshot_idx - 1) % len(snapshots)
            elif ch == curses.KEY_DOWN:
                if lstatus == "Success":
                    snapshots = snapshot_cache.get(cur_repo, [])
                    if snapshots:
                        selected_snapshot_idx = (selected_snapshot_idx + 1) % len(snapshots)
            elif ch in [ord('f'), ord('F')]:
                if is_repo_configured(cur_repo, config):
                    async_fetch_snapshots(cur_repo, config, force=True)
            elif ch in [ord('i'), ord('I')]:
                # Initialize repo
                if is_repo_configured(cur_repo, config):
                    repo_uri, env = get_repo_env(cur_repo, config)
                    # Run restic init interactive
                    cmd = ["sudo", "-E", "restic", "-r", repo_uri, "init"]
                    run_interactive_command(stdscr, cmd, env=env)
                    async_fetch_snapshots(cur_repo, config, force=True)
            elif ch in [ord('t'), ord('T')]:
                # Run Test Restore
                if lstatus == "Success":
                    snapshots = snapshot_cache.get(cur_repo, [])
                    if snapshots and selected_snapshot_idx < len(snapshots):
                        snap = snapshots[selected_snapshot_idx]
                        sid = snap.get('short_id', snap.get('id'))
                        script = find_script("vw-test-restore.sh")
                        if script:
                            # Run test-restore with repo type and snapshot ID
                            cmd = ["sudo", "-E", script, cur_repo, sid]
                            _, env = get_repo_env(cur_repo, config)
                            run_interactive_command(stdscr, cmd, env=env)
                        else:
                            run_interactive_command(stdscr, ["echo", "Error: vw-test-restore.sh script not found."])
            elif ch in [ord('r'), ord('R')]:
                # Run Full Restore
                if lstatus == "Success":
                    snapshots = snapshot_cache.get(cur_repo, [])
                    if snapshots and selected_snapshot_idx < len(snapshots):
                        snap = snapshots[selected_snapshot_idx]
                        sid = snap.get('short_id', snap.get('id'))
                        script = find_script("vw-restore.sh")
                        if script:
                            # Run restore with repo type and snapshot ID
                            cmd = ["sudo", "-E", script, cur_repo, sid]
                            _, env = get_repo_env(cur_repo, config)
                            run_interactive_command(stdscr, cmd, env=env)
                            # After restoration, reload
                            config = load_env(ENV_FILE)
                        else:
                            run_interactive_command(stdscr, ["echo", "Error: vw-restore.sh script not found."])
                            
        # ──────────────── Log Viewer Actions ────────────────
        elif active_tab == 2:
            if ch == curses.KEY_LEFT:
                selected_log_idx = (selected_log_idx - 1) % len(log_files)
                log_file_loaded = None
            elif ch == curses.KEY_RIGHT:
                selected_log_idx = (selected_log_idx + 1) % len(log_files)
                log_file_loaded = None
            elif ch == curses.KEY_UP:
                log_scroll_offset = max(0, log_scroll_offset - 1)
            elif ch == curses.KEY_DOWN:
                log_view_h = content_h - 5
                log_scroll_offset = min(max(0, len(cached_log_lines) - log_view_h), log_scroll_offset + 1)
            elif ch == curses.KEY_PPAGE: # Page Up
                log_view_h = content_h - 5
                log_scroll_offset = max(0, log_scroll_offset - log_view_h)
            elif ch == curses.KEY_NPAGE: # Page Down
                log_view_h = content_h - 5
                log_scroll_offset = min(max(0, len(cached_log_lines) - log_view_h), log_scroll_offset + log_view_h)
            elif ch in [ord('r'), ord('R')]:
                log_file_loaded = None # Forces reload
                
        # ──────────────── Configuration Actions ────────────────
        elif active_tab == 3:
            if ch in [ord('e'), ord('E')]:
                if os.path.exists(ENV_FILE):
                    editor = os.environ.get('EDITOR', 'nano')
                    run_interactive_command(stdscr, ["sudo", editor, ENV_FILE])
                    config = load_env(ENV_FILE)
                    for rtype in repos:
                        if is_repo_configured(rtype, config):
                            async_fetch_snapshots(rtype, config, force=True)

if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        print("\nExiting TUI.")
        sys.exit(0)
