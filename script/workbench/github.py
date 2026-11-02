"""Bounded account-scoped GitHub API client for Burt's workbench."""
import base64, json, os, re, urllib.error, urllib.parse, urllib.request
from pathlib import Path
API='https://api.github.com'; MAX_BODY=262144; MAX_RESPONSE=524288; DEFAULT_TOKEN=Path.home()/'.config/burt-github/token'
DENY_RULES=((r'^/repos/[^/]+/[^/]+$',{'DELETE'}),(r'^/repos/[^/]+/[^/]+/transfer$',{'POST'}),(r'^/repos/[^/]+/[^/]+/(?:keys|hooks|actions/secrets|actions/variables|dependabot/secrets|codespaces/secrets|collaborators|invitations)(?:/|$)',{'POST','PUT','PATCH','DELETE'}),(r'^/repos/[^/]+/[^/]+/environments/[^/]+/secrets(?:/|$)',{'POST','PUT','PATCH','DELETE'}),(r'^/user/(?:keys|gpg_keys|ssh_signing_keys|emails|social_accounts)(?:/|$)',{'POST','PUT','PATCH','DELETE'}),(r'^/user$',{'PATCH'}),(r'^/(?:authorizations|applications|user/installations)(?:/|$)',{'POST','PUT','PATCH','DELETE'}),(r'^/orgs/[^/]+/(?:memberships|members|invitations|outside_collaborators|roles|settings)(?:/|$)',{'POST','PUT','PATCH','DELETE'}))
class GitHubError(ValueError): pass
class GitHubHTTPError(GitHubError):
 def __init__(self,status,message,documentation_url,request_id): super().__init__('GitHub request rejected'); self.status,self.message,self.documentation_url,self.request_id=status,message,documentation_url,request_id
 def receipt(self): return {'status':self.status,'message':self.message,'documentation_url':self.documentation_url,'request_id':self.request_id}
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs): return None
def _rid(headers):
 value=headers.get('X-GitHub-Request-Id','') if headers else ''
 return value if isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}',value) else None
def safe_path(path):
 if not isinstance(path,str) or not path.startswith('/') or path.startswith('//') or '?' in path or '#' in path or '\\' in path or any(x in ('','.','..') for x in path.split('/')[1:]): raise GitHubError('GitHub path must be a relative API path beginning with /')
 return path
def denied(method,path): return any(method in methods and re.match(pattern,path) for pattern,methods in DENY_RULES)
def safe_file_path(path):
 if not isinstance(path,str) or not path or len(path)>1024 or '\\' in path or any(x in ('','.','..') for x in path.split('/')): raise GitHubError('invalid repository file path')
 return path
class GitHub:
 def __init__(self,token_file=None,opener=None): self.token_file=Path(token_file or os.environ.get('BURT_GITHUB_TOKEN_FILE',DEFAULT_TOKEN)); self.opener=opener or urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect()); self.identity=None
 def token(self):
  p=self.token_file
  if p.is_symlink() or not p.is_file() or p.stat().st_mode&0o077: raise GitHubError('GitHub credential requires a regular mode 600 file')
  token=p.read_text(encoding='utf-8').strip()
  if not token or len(token)>4096: raise GitHubError('GitHub credential is invalid')
  return token
 def request(self,method,path,query=None,body=None):
  method=method.upper() if isinstance(method,str) else ''
  if method not in ('GET','POST','PUT','PATCH','DELETE','HEAD'): raise GitHubError('invalid GitHub method')
  path=safe_path(path)
  if denied(method,path): raise GitHubError('GitHub operation is denied by policy')
  if query is not None and (not isinstance(query,dict) or any(not isinstance(k,str) or not isinstance(v,(str,int,bool)) for k,v in query.items())): raise GitHubError('invalid GitHub query')
  payload=None if body is None else json.dumps(body,separators=(',',':')).encode()
  if payload is not None and len(payload)>MAX_BODY: raise GitHubError('GitHub request body exceeds bound')
  req=urllib.request.Request(API+path+(('?'+urllib.parse.urlencode(query)) if query else ''),data=payload,method=method,headers={'Authorization':'Bearer '+self.token(),'Accept':'application/vnd.github+json','User-Agent':'burt-workbench','Content-Type':'application/json'})
  try:
   with self.opener.open(req,timeout=15) as response: raw=response.read(MAX_RESPONSE+1); headers=response.headers; status=response.status
  except urllib.error.HTTPError as exc:
   raw=exc.read(MAX_RESPONSE+1)
   if 400<=exc.code<500:
    try: data=json.loads(raw.decode())
    except Exception: data={}
    raise GitHubHTTPError(exc.code,str(data.get('message','GitHub rejected the request'))[:1000],data.get('documentation_url'),_rid(exc.headers)) from None
   raise
  if len(raw)>MAX_RESPONSE: raise GitHubError('GitHub response exceeds bound')
  try: data=None if not raw else json.loads(raw.decode())
  except Exception: raise GitHubError('GitHub returned invalid JSON') from None
  return {'status':status,'data':data,'request_id':_rid(headers),'scopes':headers.get('X-OAuth-Scopes','')}
 def whoami(self):
  if self.identity is None:
   response=self.request('GET','/user'); data=response['data']
   if not isinstance(data,dict) or not isinstance(data.get('login'),str): raise GitHubError('GitHub identity response is invalid')
   self.identity={'login':data['login'],'scopes':[s.strip() for s in response['scopes'].split(',') if s.strip()]}
  return dict(self.identity)
 def read(self,repo,ref,path):
  self._repo(repo); safe_file_path(path); response=self.request('GET',f'/repos/{repo}/contents/{urllib.parse.quote(path)}',{'ref':ref}); data=response['data']
  if isinstance(data,dict) and data.get('type')=='file':
   if data.get('encoding')!='base64' or not isinstance(data.get('content'),str): raise GitHubError('GitHub file response is invalid')
   content=base64.b64decode(data['content'],validate=True)
   if len(content)>MAX_RESPONSE: raise GitHubError('GitHub file exceeds bound')
   return {'type':'file','path':data.get('path',path),'content':content.decode('utf-8'),'sha':data.get('sha'),'request_id':response['request_id']}
  if isinstance(data,list): return {'type':'dir','entries':[{'name':x.get('name'),'path':x.get('path'),'type':x.get('type'),'sha':x.get('sha')} for x in data[:100]],'request_id':response['request_id']}
  raise GitHubError('GitHub contents response is invalid')
 def commit_files(self,repo,branch,base_ref,files,message,create_branch):
  self._repo(repo)
  if not isinstance(branch,str) or not re.fullmatch(r'[A-Za-z0-9._/-]{1,255}',branch) or branch.startswith('/') or '..' in branch.split('/'): raise GitHubError('invalid branch')
  if not isinstance(base_ref,str) or not base_ref or len(base_ref)>255: raise GitHubError('invalid base ref')
  if not isinstance(message,str) or not message.strip() or len(message)>10000: raise GitHubError('invalid commit message')
  if not isinstance(files,dict) or not 1<=len(files)<=100: raise GitHubError('files must contain 1..100 entries')
  for path,content in files.items():
   safe_file_path(path)
   if content is not None and (not isinstance(content,str) or len(content.encode())>MAX_BODY): raise GitHubError('invalid file content')
  prefix=f'/repos/{repo}/git'
  try: head=self.request('GET',f'{prefix}/ref/heads/{branch}')['data']['object']['sha']
  except GitHubHTTPError as e:
   if e.status!=404 or not create_branch: raise
   base=self.request('GET',f'{prefix}/ref/heads/{base_ref}')['data']['object']['sha']; self.request('POST',f'{prefix}/refs',body={'ref':'refs/heads/'+branch,'sha':base}); head=base
  tree_sha=self.request('GET',f'{prefix}/commits/{head}')['data']['tree']['sha']; tree=[]
  for path,content in files.items():
   if content is None: tree.append({'path':path,'mode':'100644','type':'blob','sha':None})
   else: tree.append({'path':path,'mode':'100644','type':'blob','sha':self.request('POST',f'{prefix}/blobs',body={'content':content,'encoding':'utf-8'})['data']['sha']})
  tree_sha=self.request('POST',f'{prefix}/trees',body={'base_tree':tree_sha,'tree':tree})['data']['sha']; created=self.request('POST',f'{prefix}/commits',body={'message':message,'tree':tree_sha,'parents':[head]})['data']['sha']; updated=self.request('PATCH',f'{prefix}/refs/heads/{branch}',body={'sha':created,'force':False})
  return {'repo':repo,'branch':branch,'sha':created,'request_id':updated['request_id']}
 @staticmethod
 def _repo(repo):
  if not isinstance(repo,str) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo): raise GitHubError('invalid repository')
