#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import re
import argparse
from collections import Counter,defaultdict
from dataclasses import dataclass, field
from datetime import datetime
import sys
from typing import List, Union, Callable,Sequence,TypeVar,Dict,Set

# --- Step 1: Define a Polymorphic Data Model (CORRECTED) ---

@dataclass
class BaseLogEntry:
    """Base class for all log entries."""
    timestamp: datetime
    raw_line: str

@dataclass
class RejectedLogEntry(BaseLogEntry):
    """Represents a rejected connection log entry."""
    # Non-default fields first
    source_ip: str
    reason: str
    # Constant field defined, but not included in __init__ to avoid ordering issues.
    status: str = field(default='rejected', init=False, repr=False)

@dataclass
class AcceptedLogEntry(BaseLogEntry):
    """
    Base class for accepted connections. Holds common fields WITHOUT default values.
    """
    source_ip: str
    user_email: str

@dataclass
class AcceptedTCPLogEntry(AcceptedLogEntry):
    """Represents an accepted TCP connection (the original format)."""
    # Non-default fields from this class come after non-default fields from parent.
    dest_protocol: str
    dest_site: str
    dest_port: int
    inbound_tag: str
    outbound_tag: str
    # Constant field defined at the end, not part of __init__.
    status: str = field(default='accepted', init=False, repr=False)

@dataclass
class AcceptedUDPLogEntry(AcceptedLogEntry):
    """Represents an accepted UDP connection."""
    # Non-default field
    dest_ip: str
    # Constant fields
    source_type: str = field(default='tcp', init=False, repr=False)
    dest_protocol: str = field(default='udp', init=False, repr=False)
    status: str = field(default='accepted', init=False, repr=False)

# A type hint for any of our log entry classes
AnyLogEntry = Union[AcceptedTCPLogEntry, AcceptedUDPLogEntry, RejectedLogEntry]


class LogParser:
    """
    Parses an X-ray log file with multiple formats into a list of LogEntry objects.
    """
    # Pattern for timestamps, now with optional microseconds
    TIMESTAMP_PATTERN = r"(?P<datetime>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)"
    IP_PATTERN = r"(?P<ip_raw>\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:]+\])"

    # Pattern 1: Standard accepted TCP connection
    TCP_ACCEPTED_PATTERN = re.compile(
        rf"^{TIMESTAMP_PATTERN}"
        rf" from {IP_PATTERN}:\d+"
        r" accepted "
        r"(?P<proto>\w+):(?P<site>[^:]+):(?P<port>\d+)"
        r"(?: \[(?P<inbound>\w+) -> (?P<outbound>\w+)\])?"
        r" email: (?P<email>.+)$"
    )

    # Pattern 2: Rejected connection
    REJECTED_PATTERN = re.compile(
        rf"^{TIMESTAMP_PATTERN}"
        rf" from {IP_PATTERN}:\d+"
        r" rejected\s+"
        r"(?P<reason>.+)$"
    )
    
    # Pattern 3: Accepted UDP connection
    UDP_ACCEPTED_PATTERN = re.compile(
        rf"^{TIMESTAMP_PATTERN}"
        rf" from tcp:{IP_PATTERN}:\d+"
        r" accepted "
        r"udp:(?P<dest_ip_raw>\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:]+\])"
        r" email: (?P<email>.+)$"
    )

    PATTERNS = [
        ('tcp_accepted', TCP_ACCEPTED_PATTERN),
        ('udp_accepted', UDP_ACCEPTED_PATTERN),
        ('rejected', REJECTED_PATTERN),
    ]

    def __init__(self, log_file_path: str):
        self.log_file_path = log_file_path

    def _parse_timestamp(self, ts_str: str) -> datetime:
        """Helper to parse timestamps with or without microseconds."""
        if '.' in ts_str:
            return datetime.strptime(ts_str, '%Y/%m/%d %H:%M:%S.%f')
        else:
            return datetime.strptime(ts_str, '%Y/%m/%d %H:%M:%S')

    def parse_line(self, line: str) -> AnyLogEntry | None:
        """Parses a single log line by trying multiple patterns."""
        stripped_line = line.strip()
        if not stripped_line:
            return None

        for entry_type, pattern in self.PATTERNS:
            match = pattern.match(stripped_line)
            if match:
                data = match.groupdict()
                try:
                    ts = self._parse_timestamp(data['datetime'])
                    ip = data['ip_raw'].strip('[]')

                    if entry_type == 'tcp_accepted':
                        return AcceptedTCPLogEntry(
                            timestamp=ts, raw_line=stripped_line,
                            source_ip=ip, user_email=data['email'],
                            dest_protocol=data['proto'], dest_site=data['site'], dest_port=int(data['port']),
                            inbound_tag=data.get('inbound') or 'default_in',
                            outbound_tag=data.get('outbound') or 'default_out'
                        )
                    elif entry_type == 'rejected':
                        # Note: The 'rejected' log format doesn't have an email.
                        # We'll need a placeholder or adjust the logic if we need to group by user later.
                        # Here, it doesn't inherit from AcceptedLogEntry, so it's fine.
                        return RejectedLogEntry(
                            timestamp=ts, raw_line=stripped_line,
                            source_ip=ip,
                            reason=data['reason'].strip()
                        )
                    elif entry_type == 'udp_accepted':
                        return AcceptedUDPLogEntry(
                            timestamp=ts, raw_line=stripped_line,
                            source_ip=ip, user_email=data['email'],
                            dest_ip=data['dest_ip_raw'].strip('[]')
                        )
                except (ValueError, KeyError) as e:
                    print(f"Warning: Could not parse data from matched line due to error: {e}\nLine: {stripped_line}", file=sys.stderr)
                    return None
        
        return None

    def parse_file(self) -> List[AnyLogEntry]:
        """Reads and parses the entire log file."""
        print(f"[*] Parsing log file: {self.log_file_path}")
        parsed_entries = []
        unmatched_lines = 0
        try:
            with open(self.log_file_path, 'r', encoding='utf-8') as f:
                for i, line in enumerate(f, 1):
                    entry = self.parse_line(line)
                    if entry:
                        parsed_entries.append(entry)
                    elif line.strip():
                        unmatched_lines += 1
        except FileNotFoundError:
            print(f"Error: Log file not found at '{self.log_file_path}'", file=sys.stderr)
            return []
        
        print(f"[*] Parsing complete. Found {len(parsed_entries)} valid entries. Skipped {unmatched_lines} non-conforming lines.")
        return parsed_entries

# TLog 必须是 BaseLogEntry 或其任何子类
TLog = TypeVar('TLog', bound=BaseLogEntry)
# TKey 和 TValue 可以是任何类型，所以不需要 bound
TKey = TypeVar('TKey')
TValue = TypeVar('TValue')

class LogAnalyzer:
    """Analyzes a list of various LogEntry objects to produce statistics."""
    def __init__(self, log_entries: List[AnyLogEntry]):
        self.entries = log_entries

    # ---- utility function ----
    
    @staticmethod
    def count_by(
        entries: Sequence[TLog], 
        key_func: Callable[[TLog], str], 
        max_count: int = 10
    ) -> List[tuple[str, int]]:
        """
        A generic function to count items in a sequence based on a key function.

        :param entries: A sequence of log entries (e.g., a list of AcceptedTCPLogEntry).
        :param key_func: A function that takes one entry and returns a string key to count by.
        :param max_count: The maximum number of common items to return.
        :return: A list of (key, count) tuples, sorted by count.
        """
        if not entries:
            return []
        # 使用传入的 key_func 从每个 entry 中提取用于计数的键
        counter = Counter(key_func(entry) for entry in entries)
        return counter.most_common(max_count)
    
        # --- 新的通用分组聚合函数 ---
    @staticmethod
    def group_and_aggregate(
        entries: Sequence[TLog],
        key_func: Callable[[TLog], TKey],
        value_func: Callable[[TLog], TValue]
    ) -> Dict[TKey, Set[TValue]]:
        """
        Groups entries by a key and collects unique values into a set.

        :param entries: A sequence of log entries.
        :param key_func: A function that takes an entry and returns the grouping key.
        :param value_func: A function that takes an entry and returns the value to be collected.
        :return: A dictionary mapping keys to a set of unique collected values.
        """
        # defaultdict(set) 是实现此模式最高效的方式
        # 它会自动为每个新遇到的 key 创建一个空的 set
        grouped_data = defaultdict(set)
        for entry in entries:
            key = key_func(entry)
            value = value_func(entry)
            grouped_data[key].add(value)
        # 返回一个普通的 dict，而不是 defaultdict，这样外部调用者不会感到意外
        return dict(grouped_data)
    
    def _stats_print(self, title:str, stats:list[tuple[str, int]]) -> None:
        print("\n  --- " + title + " ---")
        for stat, count in stats:
            print(f"  {stat:<40} {count} connections")

    def _group_print(self, title:str, groups:dict[str,set[str]]) -> None:
        print("\n  --- " + title + " ---")
        for group in groups:
            print("  " + group + ":")
            for item in groups[group]:
                print("  \t" + item)

    # ---- code end ----

    def print_report(self):
        """Prints a formatted summary report of the log analysis."""
        if not self.entries:
            print("\nNo data to analyze.")
            return

        print("\n--- X-ray Log Analysis Report ---")
        print(f"Total Log Entries Analyzed: {len(self.entries)}")

        # --- Overall Status ---
        status_counter = Counter(entry.status for entry in self.entries)
        print("\n--- Overall Status ---")
        for status, count in status_counter.most_common():
            print(f"{status.capitalize():<20} {count} entries")

        # --- Accepted Connection Stats ---
        accepted_entries = [e for e in self.entries if isinstance(e, AcceptedLogEntry)]
        if accepted_entries:
            print("\n--- Accepted Connection Statistics ---")
            
            user_counter = Counter(e.user_email for e in accepted_entries)
            print("\n  Top Users (Accepted Connections):")
            for email, count in user_counter.most_common(10):
                print(f"  {email:<30} {count} connections")

            ip_counter = Counter(e.source_ip for e in accepted_entries)
            print("\n  Top Source IPs (Accepted Connections):")
            for ip, count in ip_counter.most_common(10):
                print(f"  {ip:<40} {count} connections")

            
            self._stats_print("Connections by hour", sorted(self.count_by(accepted_entries, lambda e: str(e.timestamp.hour))))
            self._group_print("Group source IP by user", self.group_and_aggregate(
                accepted_entries,
                key_func=lambda e: e.user_email,
                value_func=lambda e: e.source_ip
            ))

            tcp_entries = [e for e in accepted_entries if isinstance(e, AcceptedTCPLogEntry)]
            if tcp_entries:
                outbound_counter = Counter(e.outbound_tag for e in tcp_entries)
                print("\n  Connections by Outbound Tag (TCP Only):")
                for tag, count in outbound_counter.most_common():
                    print(f"  {tag:<20} {count} connections")

            self._stats_print("Top 10 destination site", self.count_by(tcp_entries, lambda e:e.dest_site))

        # --- Rejected Connection Stats ---
        rejected_entries = [e for e in self.entries if isinstance(e, RejectedLogEntry)]
        if rejected_entries:
            print("\n--- Rejected Connection Statistics ---")
            
            reason_counter = Counter(e.reason for e in rejected_entries)
            print("\n  Top Rejection Reasons:")
            for reason, count in reason_counter.most_common(10):
                display_reason = reason[:70] + '...' if len(reason) > 73 else reason
                print(f"  {count:<4} | {display_reason}")

        print("\n--- End of Report ---")


def main():
    """Main function to run the script."""
    parser = argparse.ArgumentParser(
        description="Parse and analyze heterogeneous X-ray access logs.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("logfile", help="Path to the X-ray log file to be analyzed.")
    args = parser.parse_args()

    log_parser = LogParser(args.logfile)
    parsed_logs = log_parser.parse_file()

    if not parsed_logs:
        sys.exit(1)

    analyzer = LogAnalyzer(parsed_logs)
    analyzer.print_report()

if __name__ == "__main__":
    main()