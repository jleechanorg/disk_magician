#!/usr/bin/env python3
"""Read-only metadata traversal behind scratch_budget_measure_files."""
import os
import stat
import sys
import time


def main(argv=None):
    root, threshold, deadline, output_format = sys.argv[1:] if argv is None else argv
    if output_format not in ('tsv', '--nul'):
        sys.exit(2)
    # A trailing slash makes lstat follow a link on POSIX. Strip only slashes;
    # realpath/normpath would change ancestor-link semantics.
    root = root.rstrip(os.sep) or os.sep
    def emit_row(row):
        if output_format == '--nul':
            for value in row:
                sys.stdout.buffer.write(os.fsencode(str(value)) + b'\0')
        else:
            print('%d\t%d\t%d\t%s\t%s' % tuple(row[:5]))
    ceiling = int(threshold) * 1024 * 1024
    deadline = float(deadline) if deadline else None
    nodes = {}
    seen = set()
    failed = False
    stack = [(root, False)]


    def check_deadline():
        if deadline and time.monotonic() >= deadline:
            raise TimeoutError('measurement deadline')


    try:
        while stack:
            check_deadline()
            path, finishing = stack.pop()
            if finishing:
                node = nodes[path]
                try:
                    current = os.lstat(path)
                    if (current.st_dev, current.st_ino, current.st_mtime_ns) != node['identity']:
                        raise OSError('directory identity changed during measurement')
                except OSError:
                    node['error'] = True
                    failed = True
                children = [nodes[p] for p in node['children']]
                node['bytes'] = sum(n['bytes'] for n in children)
                node['apparent_bytes'] = sum(n['apparent_bytes'] for n in children)
                node['files'] = sum(n['files'] for n in children)
                node['newest'] = max((n['newest'] for n in children), default=0)
                node['error'] |= any(n['error'] for n in children)
                # Opaque Git roots remain visible through small non-Git ancestors;
                # otherwise their unknown bytes disappear inside an aggregate row.
                node['opaque'] = any(n['flag'] == 'G' or n['opaque'] for n in children)
                # Link leaves remain visible even below the aggregation ceiling.
                node['links'] = any(n['links'] for n in children)
                continue
            node = nodes[path] = dict(bytes=0, apparent_bytes=0, files=0, newest=0, flag='E',
                                      children=[], error=False, links=False, opaque=False)
            try:
                st = os.lstat(path)
                if stat.S_ISDIR(st.st_mode):
                    try:
                        os.lstat(os.path.join(path, '.git'))
                    except FileNotFoundError:
                        pass
                    else:
                        node['flag'] = 'G'
                        continue
                    node['flag'] = 'A'
                    node['identity'] = (st.st_dev, st.st_ino, st.st_mtime_ns)
                    with os.scandir(path) as entries:
                        for entry in entries:
                            check_deadline()
                            node['children'].append(entry.path)
                    node['children'].sort()
                    stack.append((path, True))
                    stack.extend((child, False) for child in reversed(node['children']))
                else:
                    node['flag'] = 'L' if stat.S_ISLNK(st.st_mode) else 'F'
                    node['links'] = node['flag'] == 'L'
                    identity = (st.st_dev, st.st_ino)
                    # Count shared inode bytes once, but retain each path's own
                    # mtime so a later hardlink row cannot appear to be age zero.
                    node['apparent_bytes'] = st.st_size
                    node['newest'] = max(0, int(st.st_mtime))
                    node['files'] = 1
                    if identity not in seen:
                        seen.add(identity)
                        node['bytes'] = st.st_size
            except OSError as exc:
                node['error'] = True
                node['flag'] = 'E'
                failed = True
                print('scratch_budget_measure_files: unreadable: %s: %s' % (path, exc), file=sys.stderr)

        stack = [root]
        while stack:
            check_deadline()
            path = stack.pop()
            node = nodes[path]
            if node['flag'] == 'A' and (node['apparent_bytes'] >= ceiling or node['error'] or node['links'] or node['opaque']):
                stack.extend(reversed(node['children']))
                if node['error'] and not node['children']:
                    emit_row((0, 0, 0, 'E', path, 0))
                elif node['error'] and node.get('identity'):
                    # Preserve explicit unfinished coverage even when readable
                    # siblings exist; successful child rows remain only partial.
                    emit_row((0, 0, 0, 'E', path, 0))
                continue
            emit_row((node['bytes'], node['files'], node['newest'], node['flag'], path, node['apparent_bytes']))
    except TimeoutError:
        sys.exit(124)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
