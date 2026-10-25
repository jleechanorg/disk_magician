import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1],isolation_level=None)
c.execute("BEGIN"); c.execute("SELECT count(*) FROM t").fetchone()
print("ready",flush=True)
time.sleep(float(sys.argv[2]))
