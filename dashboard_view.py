"""Scrollable terminal view of dtask; refresh without touching the task tree."""

import curses
import os
import re
import subprocess
import sys
import tempfile
import time


# tmux/screen sgr0 includes SI (0x0f); charset shifts are not visible text.
ESCAPE = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][0-2A-Z]|[\x0e\x0f]')


def parse_output(output, colors):
    """Decode dashboard SGR styles without counting escapes as visible columns."""
    lines, styles = [], []
    emphasis = foreground = 0
    for raw in output.splitlines():
        text, attrs = '', []
        position = 0
        for match in ESCAPE.finditer(raw):
            chunk = raw[position:match.start()]
            for char in chunk:
                expanded = ' ' * (8 - len(text) % 8) if char == '\t' else char
                text += expanded
                attrs.extend([emphasis | colors.get(foreground, 0)] * len(expanded))
            sequence = match.group()
            if sequence.startswith('\x1b[') and sequence.endswith('m'):
                for value in sequence[2:-1].split(';'):
                    code = int(value or '0') if value.isdigit() or not value else -1
                    if code == 0:
                        emphasis = foreground = 0
                    elif code == 1:
                        emphasis |= curses.A_BOLD
                    elif code == 2:
                        emphasis |= curses.A_DIM
                    elif code == 22:
                        emphasis &= ~(curses.A_BOLD | curses.A_DIM)
                    elif code == 39:
                        foreground = 0
                    elif 30 <= code <= 37 or 90 <= code <= 97:
                        foreground = code
            position = match.end()
        for char in raw[position:]:
            expanded = ' ' * (8 - len(text) % 8) if char == '\t' else char
            text += expanded
            attrs.extend([emphasis | colors.get(foreground, 0)] * len(expanded))
        lines.append(text)
        styles.append(attrs)
    return (lines, styles) if lines else (['(empty dashboard)'], [[]])


def terminal_colors():
    colors = {}
    if curses.has_colors():
        background = curses.COLOR_BLACK
        try:
            curses.use_default_colors()
            background = -1
        except curses.error:
            pass
        for index in range(min(16, curses.COLORS, curses.COLOR_PAIRS - 1)):
            curses.init_pair(index + 1, index, background)
            code = 30 + index if index < 8 else 90 + index - 8
            colors[code] = curses.color_pair(index + 1)
    return colors


def viewport(top, left, key, height, width, lines):
    """Move and clamp the viewport, including after resize or refresh."""
    page = max(1, height - 1)
    if key in (curses.KEY_DOWN, ord('j')):
        top += 1
    elif key in (curses.KEY_UP, ord('k')):
        top -= 1
    elif key in (curses.KEY_NPAGE, ord(' ')):
        top += page
    elif key in (curses.KEY_PPAGE, ord('b')):
        top -= page
    elif key in (curses.KEY_HOME, ord('g')):
        top = 0
    elif key in (curses.KEY_END, ord('G')):
        top = len(lines)
    elif key == curses.KEY_RIGHT:
        left += 8
    elif key == curses.KEY_LEFT:
        left -= 8
    return (max(0, min(top, max(0, len(lines) - page))),
            max(0, min(left, max(0, max(map(len, lines), default=0) - width + 1))))


def draw(screen, row, text, attr=0, column=0):
    # addstr can raise after writing the bottom-right cell on small terminals.
    try:
        screen.addnstr(row, column, text, max(0, screen.getmaxyx()[1] - column - 1), attr)
    except curses.error:
        pass


def run(screen, command):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    screen.timeout(100)
    colors = terminal_colors()
    top = left = 0
    lines = ['Loading dashboard…']
    styles = [[]]
    deadline = 0
    process = capture = None
    status = ''
    try:
        while True:
            now = time.monotonic()
            if process is None and now >= deadline:
                # A file avoids pipe-buffer deadlocks while navigation stays responsive.
                capture = tempfile.TemporaryFile()
                process = subprocess.Popen(
                    [command], stdout=capture, stderr=subprocess.STDOUT,
                    start_new_session=True)
            if process is not None and process.poll() is not None:
                capture.seek(0)
                output = capture.read().decode('utf-8', errors='replace')
                lines, styles = parse_output(output, colors)
                status = f'Refresh failed (exit {process.returncode})' if process.returncode else ''
                capture.close()
                capture = process = None
                deadline = time.monotonic() + 30
            height, width = screen.getmaxyx()
            top, left = viewport(top, left, -1, height, width, lines)
            screen.erase()
            for row, line in enumerate(lines[top:top + max(0, height - 1)]):
                visible = line[left:left + max(0, width - 1)]
                attrs = styles[top + row][left:left + len(visible)]
                start = 0
                while start < len(visible):
                    attr = attrs[start] if attrs else 0
                    end = start + 1
                    while end < len(visible) and (attrs[end] if attrs else 0) == attr:
                        end += 1
                    draw(screen, row, visible[start:end], attr, start)
                    start = end
            label = 'refreshing' if process else (status or 'refresh 30s')
            draw(screen, height - 1,
                 f'{top + 1}/{len(lines)} ↑↓ scroll  PgUp/PgDn  ←→  r refresh  q quit | {label}',
                 curses.A_REVERSE)
            screen.refresh()
            key = screen.getch()
            if key in (ord('q'), 27):
                break
            if key == ord('r'):
                deadline = 0
            top, left = viewport(top, left, key, height, width, lines)
    finally:
        if process is not None:
            # Also stop any subprocesses used by the snapshot renderer.
            import signal
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait()
        if capture is not None:
            capture.close()


if __name__ == '__main__':
    try:
        curses.wrapper(run, sys.argv[1])
    except KeyboardInterrupt:
        pass
