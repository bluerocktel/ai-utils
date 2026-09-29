"""Dashboard navigation and terminal integration, without the live task tree."""
import curses
import fcntl
import importlib.util
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('dashboard_view', ROOT / 'dashboard_view.py')
viewer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(viewer)


class DashboardTests(unittest.TestCase):
    def test_tmux_charset_reset_is_not_visible(self):
        lines, styles = viewer.parse_output(
            '\x1b[31mred\x1b[m\x0f plain\x0e\x0f', {31: 256})
        self.assertEqual(lines, ['red plain'])
        self.assertEqual(styles, [[256] * 3 + [0] * 6])

    def test_colors_resets_tabs_and_visible_width(self):
        red = 256
        lines, styles = viewer.parse_output(
            '\x1b[1m\x1b[31mRED\x1b(B\x1b[m\tplain\n'
            '\x1b[2mDIM\x1b[22m normal', {31: red})
        self.assertEqual(lines, ['RED     plain', 'DIM normal'])
        self.assertEqual(styles[0], [red | curses.A_BOLD] * 3 + [0] * 10)
        self.assertEqual(styles[1], [curses.A_DIM] * 3 + [0] * 7)
        self.assertEqual(viewer.viewport(0, 0, curses.KEY_RIGHT, 5, 10, lines), (0, 4))

    def test_navigation_resize_and_shorter_refresh(self):
        lines = ['x' * 120] * 100
        self.assertEqual(viewer.viewport(0, 0, curses.KEY_NPAGE, 10, 40, lines), (9, 0))
        self.assertEqual(viewer.viewport(9, 0, curses.KEY_END, 10, 40, lines), (91, 0))
        self.assertEqual(viewer.viewport(91, 8, -1, 20, 40, lines), (81, 8))
        self.assertEqual(viewer.viewport(91, 8, -1, 20, 40, ['short']), (0, 0))
        self.assertEqual(viewer.viewport(0, 0, curses.KEY_UP, 1, 1, []), (0, 0))

    def test_terminal_scroll_refresh_resize_and_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            renderer = Path(directory) / 'render'
            renderer.write_text(
                '#!/bin/bash\n'
                'if [[ -n "$NO_COLOR" ]]; then echo COLORS-DISABLED; exit; fi\n'
                'for ((i=0;i<100;i++)); do printf "\\033[31mROW-%s\\033(B\\033[m\\n" "$i"; done\n')
            renderer.chmod(0o755)
            master, slave = pty.openpty()
            self.addCleanup(os.close, master)
            self.addCleanup(os.close, slave)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 10, 80, 0, 0))
            before = termios.tcgetattr(slave)
            process = subprocess.Popen([sys.executable, str(ROOT / 'dashboard_view.py'), str(renderer)],
                                       stdin=slave, stdout=slave, stderr=slave,
                                       env={**os.environ, 'TERM': 'xterm-256color', 'NO_COLOR': ''})
            def stop():
                if process.poll() is None:
                    process.kill()
                process.wait()
            self.addCleanup(stop)

            def receive(expected):
                data = b''
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        data += os.read(master, 65536)
                        if expected in data:
                            return data
                self.fail(f'{expected!r} absent from terminal output: {data!r}')

            initial = receive(b'ROW-0')
            self.assertIn(b'\x1b[31m', initial)
            self.assertIn(b'\x1b[39;49m', initial)
            os.write(master, b'G')
            receive(b'92/100')  # curses may update just the changed row-number suffix.
            renderer.write_text('#!/bin/bash\nfor ((i=0;i<100;i++)); do echo "NEW-$i"; done\n')
            os.write(master, b'r')
            receive(b'NE')  # curses updates only the changed prefix of ROW -> NEW.
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 5, 30, 0, 0))
            import signal
            process.send_signal(signal.SIGWINCH)
            os.write(master, b'g')
            receive(b'1/100')
            os.write(master, b'q')
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(termios.tcgetattr(slave), before)


if __name__ == '__main__':
    unittest.main()
