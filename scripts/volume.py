#!/usr/bin/env python3
import fcntl,json,os,plistlib,subprocess,sys,tempfile,time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from dataclasses import dataclass
GIB=1024**3;MIB=1024**2;BALLOST_BYTES=64*MIB;CREATE_FREE_FLOOR=1088*MIB
@dataclass(frozen=True)
class Volume:
 name:str;uuid:str;ref:str;used:int|None;quota:int|None;roles:tuple
@dataclass(frozen=True)
class Container:
 ref:str;uuid:str;ceiling:int|None;free:int|None;volumes:tuple
 def volume_by_role(self,r):
  a=[v for v in self.volumes if r in v.roles]
  if len(a)!=1:raise ValueError("role unavailable")
  return a[0]
def diskutil_bin():return os.environ.get("DISK_MAGICIAN_DISKUTIL_BIN","/usr/sbin/diskutil")
def run(a):
 p=subprocess.run([diskutil_bin(),*a],capture_output=True,timeout=15)
 if p.returncode:raise RuntimeError("diskutil operation failed")
 return p.stdout
def load_container():
 cs=plistlib.loads(run(["apfs","list","-plist"])).get("Containers") or []
 if len(cs)!=1:raise ValueError("container unavailable")
 c=cs[0];vs=[]
 for x in c.get("Volumes") or []:
  t=(x.get("Name"),x.get("APFSVolumeUUID"),x.get("DeviceIdentifier"))
  if not all(isinstance(z,str) and z for z in t):raise ValueError("incomplete identity")
  vs.append(Volume(*t,x.get("CapacityInUse"),x.get("CapacityQuota"),tuple(x.get("Roles") or [])))
 return Container(c.get("ContainerReference"),c.get("APFSContainerUUID"),c.get("CapacityCeiling"),c.get("CapacityFree"),tuple(vs))
def config():
 import resolve_config
 v=json.loads(Path(resolve_config.resolve()).read_text()).get("volumes")
 if not isinstance(v,dict) or not isinstance(v.get("classes"),dict):raise ValueError("quota configuration unavailable")
 return v
def cls(n):
 v=config();x=v["classes"].get(n)
 if not isinstance(x,dict) or not isinstance(x.get("name"),str) or not x["name"].startswith("diskm-") or not isinstance(x.get("mountpoint"),str) or not Path(x["mountpoint"]).is_absolute() or not isinstance(x.get("quota_gb"),int) or x["quota_gb"]<=0:raise ValueError("invalid volume class")
 return v,x
def fit_result(c=None):
 c=c or load_container();v=config();d=c.volume_by_role("Data").used;s=c.volume_by_role("System").used;m=c.volume_by_role("VM").used
 if any(not isinstance(z,int) or z<0 for z in (d,s,m,c.ceiling)):raise ValueError("capacity unavailable")
 swap=int(v.get("swap_headroom_gb",40))*GIB;floor=int(v.get("alarm_floor_gb",20))*GIB
 quotas=[int(x.get("quota_gb",0))*GIB for x in v["classes"].values()]
 if any(q<=0 for q in quotas):raise ValueError("invalid quota")
 reserve=max(m,swap);base=d+s+reserve+floor;quota=sum(quotas);need=base+quota
 return {"ok":need<=c.ceiling,"fits":need<=c.ceiling,"required_bytes":need,"ceiling_bytes":c.ceiling,"data_used_bytes":d,"system_used_bytes":s,"vm_reserve_bytes":reserve,"quota_bytes":quota,"alarm_floor_bytes":floor,"max_quota_gb_that_fits":max(0,(c.ceiling-base-sum(quotas[1:]))//GIB)}

def paths():
 p=Path(os.environ.get("DISK_MAGICIAN_STATE_DIR",Path.home()/".disk_magician_state"))/"volumes";p.mkdir(parents=True,exist_ok=True);return p/"registry.json",p/"registry.lock"
def registry():
 p,_=paths()
 try:d=json.loads(p.read_text())
 except FileNotFoundError:return {"schema_version":1,"volumes":{}}
 if d.get("schema_version")!=1 or not isinstance(d.get("volumes"),dict):raise ValueError("bad registry")
 return d
def locked():
 p,l=paths();f=open(l,"a+");fcntl.flock(f,fcntl.LOCK_EX);return p,f
def save(p,f,d):
 fd,t=tempfile.mkstemp(prefix=".registry-",dir=p.parent)
 with os.fdopen(fd,"w") as h:json.dump(d,h,sort_keys=True);h.flush();os.fsync(h.fileno())
 os.replace(t,p);q=os.open(p.parent,os.O_DIRECTORY);os.fsync(q);os.close(q);f.close()
def live(c,x):
 z=next((z for z in c.volumes if z.name==x["name"]),None)
 if z is None:return None
 i=plistlib.loads(run(["info","-plist",x["mountpoint"]]))
 if i.get("VolumeUUID")!=z.uuid or i.get("MountPoint")!=x["mountpoint"] or i.get("APFSContainerReference")!=c.ref or z.roles:raise ValueError("volume identity mismatch")
 return z
def ballast(mp):return Path(mp)/".diskm-ballast"
def ballast_ok(mp):
 p=ballast(mp)
 try:s=p.stat()
 except OSError:return False
 return p.is_file() and not p.is_symlink() and s.st_size==BALLOST_BYTES and s.st_blocks*512>=BALLOST_BYTES
def write_ballast(mp):
 fd=os.open(ballast(mp),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
 with os.fdopen(fd,"wb") as h:h.write(b"\0"*BALLOST_BYTES);h.flush();os.fsync(h.fileno())
 if not ballast_ok(mp):raise RuntimeError("ballast allocation verification failed")
def path_cmd(n,for_reclaim=False):
 _,x=cls(n);r=registry()["volumes"].get(n,{})
 if r.get("state")=="retired" and not for_reclaim:return 3
 if r.get("state")!="active" and not (for_reclaim and r.get("state")=="retired"):return 3
 try:z=live(load_container(),x)
 except Exception:return 75
 if z is None or (r.get("uuid") and r["uuid"]!=z.uuid) or (r.get("container_uuid") and r["container_uuid"]!=load_container().uuid) or not ballast_ok(x["mountpoint"]):return 75
 print(x["mountpoint"]);return 0
def ballast_cmd(a,n):
 _,x=cls(n);c=load_container();r=registry()["volumes"].get(n,{});z=live(c,x)
 if z is None or (r.get("uuid") and r["uuid"]!=z.uuid) or (r.get("container_uuid") and r["container_uuid"]!=c.uuid):return 75
 p=ballast(x["mountpoint"])
 if a=="ensure":
  if ballast_ok(x["mountpoint"]):return 0
  if z.used is None or z.quota is None or z.quota-z.used<CREATE_FREE_FLOOR:return 75
  write_ballast(x["mountpoint"]);return 0 if ballast_ok(x["mountpoint"]) else 75
 if a=="release":
  if not ballast_ok(x["mountpoint"]):return 75
  p.unlink()
  subprocess.run(["bash","-c",'source "$1"; deletion_log volume release_ballast 0 "$2" "$3"',"volume",str(Path(__file__).resolve().parent/"safety_lib.sh"),str(p),"uuid="+z.uuid],check=False)
  return 0
 raise ValueError("unknown ballast action")
def create_cmd(n,execute=False):
 v,x=cls(n);r=registry()["volumes"].get(n,{})
 if v.get("encryption")=="none" and not v.get("encryption_acknowledged_at"):return 2
 c=load_container()
 if r.get("state")=="active" or any(z.name==x["name"] for z in c.volumes):return 2
 try:f=fit_result(c)
 except Exception:return 2
 if not f["fits"]:return 2
 if not execute:print(json.dumps({"class":n,"fits":True,"quota_gb":x["quota_gb"],"mountpoint":x["mountpoint"]}));return 0
 if c.free is None or c.free<int(v.get("alarm_floor_gb",20))*GIB:return 75
 run(["apfs","addVolume",c.ref,"APFS",x["name"],"-quota",str(x["quota_gb"])+"g"]);c=load_container();z=next((z for z in c.volumes if z.name==x["name"]),None)
 if z is None or Path(x["mountpoint"]).exists():return 75
 try:
  run(["mount",z.ref]);i=plistlib.loads(run(["info","-plist",x["mountpoint"]]))
  if i.get("VolumeUUID")!=z.uuid or i.get("MountPoint")!=x["mountpoint"] or i.get("APFSContainerReference")!=c.ref or z.roles:return 75
  write_ballast(x["mountpoint"]);p,h=locked();d=registry();d["volumes"][n]={"class":n,"name":z.name,"uuid":z.uuid,"container_uuid":c.uuid,"mountpoint":x["mountpoint"],"state":"active","quota_bytes":x["quota_gb"]*GIB,"created_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())};save(p,h,d)
 except Exception:return 75
 return 0

def retire_cmd(n):
 _,x=cls(n);c=load_container();p,h=locked();d=registry();r=d["volumes"].get(n)
 if not r:h.close();return 3
 try:z=live(c,x)
 except Exception:h.close();return 75
 if z is None or r.get("uuid")!=z.uuid or r.get("container_uuid")!=c.uuid:h.close();return 75
 r["state"]="retired";r["retired_at"]=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime());save(p,h,d);return 0
def status(snapshot=False):
 ts=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime());alarms=[];rows=[]
 try:
  c=load_container();regs=registry()["volumes"];classes=config()["classes"]
  if c.free is None or c.ceiling is None:raise ValueError("container capacity unavailable")
  if c.free<10*GIB:alarms.append("container_critical")
  elif c.free<20*GIB:alarms.append("container_low")
  for n,x in classes.items():
   r=regs.get(n,{})
   try:
    z=live(c,x)
    if z is None or (r.get("uuid") and r["uuid"]!=z.uuid) or (r.get("container_uuid") and r["container_uuid"]!=c.uuid) or z.used is None or z.quota is None or z.quota<=0:raise ValueError("volume measurement unavailable")
    pct=z.used/z.quota
    if pct>=1:alarms.append("volume_full")
    elif pct>=.9:alarms.append("volume_high")
    rows.append({"host_id":os.uname().nodename,"filesystem_id":z.uuid,"kind":"filesystem","source":"apfs_volume","path":x["mountpoint"],"class":n,"allocated_bytes":z.used,"quota_bytes":z.quota,"measured_at":ts,"status":r.get("state","unavailable"),"available":ballast_ok(x["mountpoint"]),"attribution":"exclusive_exact"})
   except Exception:
    rows.append({"host_id":os.uname().nodename,"filesystem_id":r.get("uuid"),"kind":"filesystem","source":"apfs_volume","path":x.get("mountpoint"),"class":n,"allocated_bytes":None,"quota_bytes":None,"measured_at":None,"status":r.get("state","unavailable"),"available":False,"attribution":"exclusive_exact"})
    if r.get("state")=="active":alarms.append("volume_measurement_unavailable:"+n)
  o={"measured_at":ts,"container":{"filesystem_id":c.uuid,"source":"apfs_container","ceiling_bytes":c.ceiling,"free_bytes":c.free},"volumes":rows,"alarms":alarms}
 except Exception:
  o={"measured_at":None,"container":{"filesystem_id":None,"source":"apfs_container","ceiling_bytes":None,"free_bytes":None},"volumes":[],"alarms":["volume_measurement_unavailable"]}
 if not snapshot:o["tmp_audit"]=audit_tmp()
 print(json.dumps(o,sort_keys=True));return 1 if o["alarms"] else 0

def audit_tmp(path=None):
 if path is None:
  resolver=Path(__file__).resolve().parent/"lib"/"resolve_snapshot_json.sh"
  p=subprocess.run(["bash","-c",'source "$1"; resolve_snapshot_json',"resolve_snapshot",str(resolver)],capture_output=True,text=True,timeout=5)
  if p.returncode:return {"status":"unknown","reason":"snapshot_unavailable","candidates":[]}
  path=p.stdout.strip()
 try:d=json.loads(Path(path).read_text())
 except Exception:return {"status":"unknown","reason":"snapshot_unavailable","candidates":[]}
 ts=d.get("snapshot_ts") or d.get("timestamp");items=d.get("directories") or d.get("top_directories") or []
 if isinstance(items,dict):items=[dict(path=k,**(v if isinstance(v,dict) else {"size_bytes":v})) for k,v in items.items()]
 rows=[]
 for x in items:
  p=x.get("path") or x.get("name");b=x.get("size_bytes")
  if isinstance(p,str) and p.startswith("/private/tmp/") and isinstance(b,(int,float)) and b>=GIB:rows.append({"path":p,"size_bytes":b,"measured_at":ts})
 return {"status":"measured" if ts is not None else "unknown","measured_at":ts,"candidates":rows}
def main(argv=None):
 a=list(argv if argv is not None else sys.argv[1:])
 try:
  if a[:1]==["path"] and len(a)>1:return path_cmd(a[1],"--for-reclaim" in a[2:])
  if a[:1] in (["fit"],["plan-fit"]):print(json.dumps(fit_result(),sort_keys=True));return 0
  if a[:1]==["create"] and len(a)>1:return create_cmd(a[1],"--execute" in a[2:])
  if a[:1]==["retire"] and len(a)>1:return retire_cmd(a[1])
  if a[:1]==["ballast"] and len(a)>2:return ballast_cmd(a[1],a[2])
  if a[:1]==["status"]:return status("--snapshot" in a[1:])
  if a[:1]==["audit-tmp"]:print(json.dumps(audit_tmp(a[1] if len(a)>1 else None),sort_keys=True));return 0
  return 2
 except Exception as e:print("volume: "+str(e),file=sys.stderr);return 75
if __name__=="__main__":raise SystemExit(main())
