#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# author  : gtx000

import re
import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
import sys,os
from typing import Callable

@dataclass
class LogEntry:
    """Represents a single parsed log entry."""
    timestamp: datetime
    source_ip: str
    dest_protocol: str
    dest_site: str
    dest_port: int
    inbound_tag: str
    outbound_tag: str
    user_email: str

class LogParser:
    """
    Parses an X-ray log file into a list of LogEntry objects.
    """
    # Regex updated to handle both IPv4 and bracketed IPv6 addresses.
    # It now looks for either a standard IPv4 or a bracketed sequence of hex/colon chars.
    # 2025/07/10 18:46:00.146350 from [240e:36c:b09f:8201:a5e8:7081:fab4:385a]:0 accepted tcp:mtalk.google.com:5228 [in_vless -> WARP_out] email: 1650032059@qq.com
    LOG_PATTERN = re.compile(
        r"^(?P<datetime>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\.\d{6}"
        # --- MODIFIED PART START ---
        r" from (?P<ip_raw>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[[0-9a-fA-F:]+\]):\d+"
        # --- MODIFIED PART END ---
        r" accepted "
        r"(?P<proto>\w+):(?P<site>[^:]+):(?P<port>\d+)"
        r"(?: \[(?P<inbound>\w+) -> (?P<outbound>\w+)\])?"
        r" email: (?P<email>.+)$"
    )

    def __init__(self, log_file_path: str):
        """
        Initializes the parser with the path to the log file.
        
        :param log_file_path: Path to the X-ray log file.
        """
        self.log_file_path = log_file_path
        self.parsed_entries = []

    def parse_line(self, line: str) -> LogEntry | None:
        """
        Parses a single log line.

        :param line: A string representing one line from the log file.
        :return: A LogEntry object if parsing is successful, otherwise None.
        """
        match = self.LOG_PATTERN.match(line.strip())
        if not match:
            return None
        
        data = match.groupdict()
        
        try:
            # --- MODIFIED PART START ---
            # Get the raw IP and strip brackets if they exist (for IPv6)
            source_ip = data['ip_raw'].strip('[]')
            # --- MODIFIED PART END ---

            inbound_tag = data.get('inbound') or 'default_in'
            outbound_tag = data.get('outbound') or 'default_out'

            return LogEntry(
                timestamp=datetime.strptime(data['datetime'], '%Y/%m/%d %H:%M:%S'),
                source_ip=source_ip, # Use the cleaned IP
                dest_protocol=data['proto'],
                dest_site=data['site'],
                dest_port=int(data['port']),
                inbound_tag=inbound_tag,
                outbound_tag=outbound_tag,
                user_email=data['email']
            )
        except (ValueError, KeyError) as e:
            print(f"Warning: Could not parse data from a matched line due to error: {e}", file=sys.stderr)
            return None

    def parse_file(self) -> list[LogEntry]:
        """
        Reads and parses the entire log file.

        :return: A list of successfully parsed LogEntry objects.
        """
        print(f"[*] Parsing log file: {self.log_file_path}")
        try:
            with open(self.log_file_path, 'r', encoding='utf-8') as f:
                for i, line in enumerate(f, 1):
                    entry = self.parse_line(line)
                    if entry:
                        self.parsed_entries.append(entry)
                    elif line.strip():
                        print(f"Warning: Line {i} did not match expected format: {line.strip()}", file=sys.stderr)
        except FileNotFoundError:
            print(f"Error: Log file not found at '{self.log_file_path}'", file=sys.stderr)
            return []
        
        print(f"[*] Parsing complete. Found {len(self.parsed_entries)} valid log entries.")
        return self.parsed_entries


class LogAnalyzer:
    """
    Analyzes a list of LogEntry objects to produce statistics.
    """
    def __init__(self, log_entries: list[LogEntry]):
        """
        Initializes the analyzer with parsed log data.
        
        :param log_entries: A list of LogEntry objects.
        """
        self.entries = log_entries

    def get_total_connections(self) -> int:
        """Returns the total number of connections."""
        return len(self.entries)

    def get_stats_by_ip(self, top_n: int = 10) -> list[tuple[str, int]]:
        """Gets connection counts by source IP."""
        if not self.entries:
            return []
        ip_counter = Counter(entry.source_ip for entry in self.entries)
        return ip_counter.most_common(top_n)

    def get_stats_by_user(self, top_n: int = 10) -> list[tuple[str, int]]:
        """Gets connection counts by user email."""
        if not self.entries:
            return []
        user_counter = Counter(entry.user_email for entry in self.entries)
        return user_counter.most_common(top_n)

    def get_stats_by_outbound(self) -> list[tuple[str, int]]:
        """Gets connection counts by outbound tag."""
        if not self.entries:
            return []
        outbound_counter = Counter(entry.outbound_tag for entry in self.entries)
        return outbound_counter.most_common()
    
    def get_stats_by_site(self) -> list[tuple[str, int]]:
        if not self.entries:
            return []
        site_counter = Counter(entry.dest_site for entry in self.entries)
        return site_counter.most_common()
    
    def get_stats_by_hour(self) -> list[tuple[str, int]]:
        if not self.entries:
            return []
        hour_counter = Counter(str(entry.timestamp.hour) for entry in self.entries)
        return hour_counter.most_common()
    
    def group_ip_by_user(self) -> dict[str,set[str]]:
        ips:dict[str,set[str]] = {}
        for entry in self.entries:
            if entry.user_email in ips:
                ips[entry.user_email].add(entry.source_ip)
            else:
                ips[entry.user_email] = set()
                ips[entry.user_email].add(entry.source_ip)
        return ips
    
    def count_by(self, fun:Callable[[LogEntry],str], max_count:int=30) -> list[tuple[str, int]]:
        if not self.entries:
            return []
        hour_counter = Counter(fun(entry) for entry in self.entries)
        return hour_counter.most_common(max_count)

    def print_report(self):
        """Prints a formatted summary report of the log analysis."""
        if not self.entries:
            print("\nNo data to analyze.")
            return

        print("\n--- X-ray Log Analysis Report ---")
        print(f"Total Connections: {self.get_total_connections()}")

        print("\n--- Top 10 Source IPs ---")
        # --- MODIFIED PART START ---
        # Increased width to accommodate longer IPv6 addresses
        for ip, count in self.get_stats_by_ip():
            print(f"{ip:<40} {count} connections")
        # --- MODIFIED PART END ---
            
        print("\n--- Top 10 Users (by Email) ---")
        for email, count in self.get_stats_by_user():
            print(f"{email:<30} {count} connections")
            
        print("\n--- Connections by Outbound Tag ---")
        for tag, count in self.get_stats_by_outbound():
            print(f"{tag:<20} {count} connections")

        self._stats_print("Top 10 destination site", self.count_by(lambda e:e.dest_site))
        self._stats_print("Connections by hour", sorted(self.get_stats_by_hour()))
        self._group_print("Group source IP by user", self.group_ip_by_user())
            
        print("\n--- End of Report ---")

    def _stats_print(self, title:str, stats:list[tuple[str, int]]) -> None:
        print("\n--- " + title + " ---")
        for stat, count in stats:
            print(f"{stat:<40} {count} connections")

    def _group_print(self, title:str, groups:dict[str,set[str]]) -> None:
        print("\n--- " + title + " ---")
        for group in groups:
            print(group + ":")
            for item in groups[group]:
                print("\t" + item)

def main():
    """Main function to run the script."""
    parser = argparse.ArgumentParser(
        description="Parse and analyze X-ray access logs (supports IPv4 and IPv6).",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument(
        "logfile",
        help="Path to the X-ray log file to be analyzed."
    )
    args = parser.parse_args()

    # 1. Parse the log file
    log_parser = LogParser(args.logfile)
    parsed_logs = log_parser.parse_file()

    if not parsed_logs:
        sys.exit(1)

    # 2. Analyze the data
    analyzer = LogAnalyzer(parsed_logs)

    # 3. Print the report
    analyzer.print_report()

if __name__ == "__main__":
    print(os.getcwd())
    main()