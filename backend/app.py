"""Small private-group service. Run behind an HTTPS reverse proxy."""
import os, json, time, hmac, hashlib, secrets, sqlite3, base64, urllib.request, urllib.error, re, wave, io
from xml.sax.saxutils import escape, quoteattr
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import mimetypes

DATA = Path(os.environ.get('LAOLINGO_DATA', './data'))
DATA.mkdir(parents=True, exist_ok=True)
os.chmod(DATA, 0o700)
DB = DATA / 'users.sqlite'
CONFIG = DATA / 'config.json'
ADMIN = os.environ.get('LAOLINGO_ADMIN_TOKEN', '')
FEATURES = ('daily','legal','analysis','dictionary','vision','stt','tts')
DEFAULT = {'base_url':'https://api.deepseek.com','model':'deepseek-flash','api_key':'','enabled':True,'voice':'alloy','provider':'openai','region':'eastasia','chinese_voice':'zh-CN-XiaoxiaoNeural'}

CF_STT_DEFAULT = {'provider':'cloudflare','base_url':'https://wild-moon-4450.62t2fyrpvw.workers.dev','model':'@cf/openai/whisper-large-v3-turbo','api_key':'','enabled':False}

HUB_TTS_DEFAULT = {'provider':'hub','base_url':'https://api.h234.cn','voice':'lo-LA-KeomanyNeural','chinese_voice':'zh-CN-XiaoxiaoNeural','enabled':False}

def db():
    c=sqlite3.connect(DB,timeout=15); c.row_factory=sqlite3.Row; return c

def init():
    with db() as c:
        c.executescript('''CREATE TABLE IF NOT EXISTS users(name TEXT PRIMARY KEY,salt TEXT NOT NULL,password TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1,daily_limit INTEGER NOT NULL DEFAULT 100);
CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY,name TEXT,expires INTEGER);
CREATE TABLE IF NOT EXISTS usage(name TEXT,day TEXT,count INTEGER,PRIMARY KEY(name,day));
CREATE TABLE IF NOT EXISTS attempts(ip TEXT PRIMARY KEY,count INTEGER,until INTEGER);''')
    # Preserve still-valid sessions; do not revive expired or revoked logins.
    with db() as c: c.execute('UPDATE sessions SET expires=0 WHERE expires>?',(int(time.time()),))
    os.chmod(DB,0o600)
    # Provider credentials remain in the existing private server configuration.

def config():
    saved=json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    if 'base_url' in saved: saved={f:saved for f in FEATURES}
    profiles={f:{**DEFAULT,**saved.get(f,{}), 'enabled':saved.get(f,{}).get('enabled',f not in ('stt','tts'))} for f in FEATURES}
    stt=saved.get('stt',{})
    # Preset only an unconfigured/invalid default. Never send an existing service key to a new host.
    if not stt.get('api_key') and stt.get('provider','openai')=='openai' and urlsplit(stt.get('base_url',DEFAULT['base_url'])).hostname=='api.deepseek.com':
        profiles['stt']={**profiles['stt'],**CF_STT_DEFAULT}
    tts=saved.get('tts',{})
    if not tts.get('api_key'):
        # Preset Hub only for an unconfigured profile. Never forward an existing provider key elsewhere.
        profiles['tts']={**profiles['tts'],**HUB_TTS_DEFAULT,'enabled':tts.get('enabled',False)}
    return profiles

def save_config(value):
    temp=CONFIG.with_suffix('.tmp')
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as out: json.dump(value,out,ensure_ascii=False)
    os.replace(temp,CONFIG)

def password(value,salt): return hashlib.scrypt(value.encode(),salt=bytes.fromhex(salt),n=16384,r=8,p=1).hex()
def digest(value): return hashlib.sha256(value.encode()).hexdigest()

class Problem(Exception):
    def __init__(self,message,status=400): self.message=message;self.status=status

def validate_transcription_service(cfg):
    # OpenAI-compatible chat does not imply audio/transcriptions support.
    if urlsplit(cfg.get('base_url','')).hostname=='api.deepseek.com':
        raise Problem('DeepSeek 官方接口未提供本应用所需的语音转文字接口；请在后台“语音识别”单独配置支持音频转写的服务。日常文字翻译可继续使用 DeepSeek。',503)

def upstream(cfg,path,payload,raw=False,body=None,content_type='application/json'):
    if path=='/audio/transcriptions': validate_transcription_service(cfg)
    if not cfg['enabled']: raise Problem('此功能尚未启用',503)
    if not cfg['api_key']: raise Problem('管理员尚未配置此功能的 API 密钥',503)
    target=cfg['base_url'].rstrip('/')+path
    data=body if body is not None else json.dumps(payload,ensure_ascii=False).encode()
    req=urllib.request.Request(target,data=data,headers={'Authorization':'Bearer '+cfg['api_key'],'Content-Type':content_type,'User-Agent':'LaoLingo/1.2.0'})
    # Do not follow redirects with provider credentials.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs): return None
    try:
        with urllib.request.build_opener(NoRedirect).open(req,timeout=100 if path=='/audio/transcriptions' else 75) as response:
            result=response.read(12*1024*1024+1)
        if len(result)>12*1024*1024: raise Problem('服务返回内容过大',502)
        return result if raw else json.loads(result)
    except urllib.error.HTTPError as e:
        label={'/audio/transcriptions':'语音识别服务','/audio/speech':'语音合成服务'}.get(path,'模型服务')
        detail={400:'请求参数或模型不被支持',401:'服务密钥无效或未授权',402:'服务余额不足或需要充值',403:'服务拒绝访问，请检查权限与地区限制',404:'接口不存在或模型不存在，请检查接口根地址、接口能力及模型名称',408:'上游处理超时',413:'音频或请求内容过大',415:'服务不支持当前音频或请求格式',422:'请求参数或音频格式不被支持',429:'服务限流或可用额度不足',500:'上游服务内部错误',502:'上游网关错误',503:'上游服务暂不可用',504:'上游处理超时'}.get(e.code,'上游请求失败')
        if cfg.get('provider')=='cloudflare' and path=='/audio/transcriptions':
            detail={401:'Worker 访问口令不正确，请核对后台 STT_TOKEN',403:'Worker 拒绝访问，请检查 Cloudflare 访问限制',429:'Cloudflare AI 额度不足或请求过于频繁',503:'Worker 的 AI 绑定或 STT_TOKEN 尚未正确配置'}.get(e.code,detail)
        e.close()
        # Keep provider auth failures as 502: 401 belongs to our own app login.
        # Never forward raw provider bodies, which may echo keys or private text.
        raise Problem(label+' HTTP '+str(e.code)+'：'+detail,502) from e
    except TimeoutError as e: raise Problem('服务连接或处理超时，请稍后重试；若持续超时，请检查服务器到服务商的网络及模型响应速度。',502) from e
    except urllib.error.URLError as e:
        if isinstance(e.reason,TimeoutError): raise Problem('服务连接或处理超时，请稍后重试。',502) from e
        raise Problem('服务器无法连接上游服务，请检查接口地址、DNS、HTTPS 证书及服务器出站网络。',502) from e
    except (ValueError,UnicodeError) as e: raise Problem('上游返回的内容不是有效 JSON，请检查接口根地址和兼容格式。',502) from e

def azure_transcribe(cfg,audio,language,fmt):
    if not cfg.get('enabled'): raise Problem('语音识别尚未启用',503)
    if not cfg.get('api_key'): raise Problem('管理员尚未配置语音识别密钥',503)
    region=cfg.get('region','')
    if not re.fullmatch(r'[a-z][a-z0-9-]{1,39}',region): raise Problem('Azure 区域无效')
    if language not in ('zh','lo'): raise Problem('请选择中文或老挝语识别')
    if fmt!='wav': raise Problem('Azure 识别目前仅支持 16 kHz 单声道 PCM WAV 录音')
    try:
        with wave.open(io.BytesIO(audio),'rb') as w:
            if (w.getnchannels(),w.getsampwidth(),w.getframerate(),w.getcomptype())!=(1,2,16000,'NONE') or not 0<w.getnframes()<=16000*60:
                raise ValueError()
    except (wave.Error,EOFError,ValueError): raise Problem('录音须为不超过 60 秒的 16 kHz 单声道 PCM WAV')
    lang={'zh':'zh-CN','lo':'lo-LA'}[language]
    url='https://'+region+'.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language='+lang
    req=urllib.request.Request(url,data=audio,headers={'Ocp-Apim-Subscription-Key':cfg['api_key'],'Content-Type':'audio/wav; codecs=audio/pcm; samplerate=16000','Accept':'application/json'})
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs): return None
    try:
        with urllib.request.build_opener(NoRedirect).open(req,timeout=45) as response: result=json.loads(response.read(65536))
    except urllib.error.HTTPError as e: raise Problem('语音识别服务请求失败（HTTP %d），请检查密钥、地区或额度。'%e.code,502) from e
    except (urllib.error.URLError,TimeoutError,OSError): raise Problem('无法连接语音识别服务，请稍后重试',502)
    except (ValueError,UnicodeError): raise Problem('语音识别服务返回异常',502)
    if result.get('RecognitionStatus')!='Success' or not result.get('DisplayText','').strip(): raise Problem('未识别到文字，请靠近麦克风并重新录音',422)
    return {'text':result['DisplayText'].strip()}

def azure_speech(cfg,text,language="auto"):
    if not cfg['enabled']: raise Problem('语音合成未启用',503)
    relay=cfg.get('provider')=='hub'
    if not cfg['api_key']: raise Problem('请配置语音服务密钥',503)
    region=cfg.get('region','')
    if not relay and not re.fullmatch(r'[a-z][a-z0-9-]{1,39}',region): raise Problem('Azure 区域无效')
    if language not in ('auto','lo','zh'):raise Problem('朗读语言仅支持 auto、lo 或 zh')
    lao=language=='lo' or (language=='auto' and any('\u0e80'<=ch<='\u0eff' for ch in text))
    voice=cfg.get('voice','') if lao else cfg.get('chinese_voice','zh-CN-XiaoxiaoNeural')
    if lao and voice in ('','alloy'): voice='lo-LA-KeomanyNeural'
    lang='lo-LA' if lao else 'zh-CN'
    xml=('<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang='+quoteattr(lang)+'><voice name='+quoteattr(voice)+'>'+escape(text)+'</voice></speak>').encode()
    endpoint=cfg['base_url'].rstrip('/')+'/cognitiveservices/v1' if relay else 'https://'+region+'.tts.speech.microsoft.com/cognitiveservices/v1'
    req=urllib.request.Request(endpoint,data=xml,headers={'Ocp-Apim-Subscription-Key':cfg['api_key'],'Content-Type':'application/ssml+xml','X-Microsoft-OutputFormat':'audio-24khz-48kbitrate-mono-mp3','User-Agent':'LaoLingo'})
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs):return None
    try:
        with urllib.request.build_opener(NoRedirect).open(req,timeout=75) as r:audio=r.read(12*1024*1024+1)
        if not audio or len(audio)>12*1024*1024:raise Problem('语音服务未返回有效音频',502)
        return audio
    except urllib.error.HTTPError as e:
        detail={400:'请求参数或 SSML 有误',401:'密钥无效、未授权或余额不足',403:'服务拒绝访问',415:'音频或请求格式不支持',429:'超过并发或频率限制',502:'上游网关错误',503:'上游服务暂不可用'}.get(e.code,'请求失败')
        raise Problem('语音服务 HTTP '+str(e.code)+'：'+detail,502) from e
    except (urllib.error.URLError,TimeoutError) as e:raise Problem('语音服务连接失败，请检查服务器网络与接口地址',502) from e

def chat(cfg,messages):
    r=upstream(cfg,'/chat/completions',{'model':cfg['model'],'messages':messages})
    try: text=r['choices'][0]['message']['content']
    except (KeyError,IndexError,TypeError): raise Problem('模型返回格式无效',502)
    if not isinstance(text,str) or not text.strip(): raise Problem('模型未返回文字',502)
    return text

def structured_json(text):
    value=text.strip()
    if value.startswith('```'):
        lines=value.splitlines()
        if len(lines)<3 or lines[-1].strip()!='```':raise Problem('AI 返回格式无效，请重试',502)
        value='\n'.join(lines[1:-1])
    try:result=json.loads(value)
    except (ValueError,TypeError):raise Problem('AI 未返回有效学习数据，请重试',502)
    if not isinstance(result,dict):raise Problem('AI 返回格式无效，请重试',502)
    return result

# Script checks catch common model mix-ups but do not guarantee semantic accuracy.
def unexpected_thai_issue(source,translation):
    source_thai=set(re.findall(r'[\u0e01-\u0e3a\u0e40-\u0e4e]+',source))
    output_thai=re.findall(r'[\u0e01-\u0e3a\u0e40-\u0e4e]+',translation)
    if any(part not in source_thai for part in output_thai):
        return '译文包含原文没有的泰文字母'
    return ''

def lao_translation_issue(source,translation):
    problem=unexpected_thai_issue(source,translation)
    if problem:return problem
    if re.search(r'[\u3400-\u9fff]',source) and not re.search(r'[\u0e81-\u0eae]',translation):
        return '译文缺少老挝文字'
    return ''

def translate_daily(cfg,text,direction):
    target='老挝语（Lao）' if direction=='zh-lo' else '简体中文'
    prompt=('你是中文和老挝语翻译。准确翻译至'+target+'，仅输出译文。'
            '中译老使用老挝语和老挝文字，老译中使用简体中文；不得擅自改成泰语或其他语种，也不得凭空混入其他语言。'
            '忠实保持原意，不要增添原文没有的信息；原文中出现的外文、专有名称、品牌、数字和引用应按上下文保留。')
    messages=[{'role':'system','content':prompt},{'role':'user','content':text}]
    result=chat(cfg,messages)
    checker=lao_translation_issue if direction=='zh-lo' else unexpected_thai_issue
    issue=checker(text,result)
    if issue:
        # A single retry keeps latency and provider costs bounded.
        messages=messages+[{'role':'assistant','content':result},{'role':'user','content':'上次译文有误：'+issue+'。请按原文和目标语言重新准确翻译，只输出译文；不得擅自混入泰语等其他语种，保留原文必要的专有名词。'}]
        result=chat(cfg,messages)
        if checker(text,result):raise Problem('译文可能包含不符合要求的语种，未保存结果；请重试或补充上下文。',502)
    return result

def study_pairs(source,target,direction,phonetics=False,easy_reading=False,explanation_language="zh"):
    if (lao_translation_issue(source,target) if direction=='zh-lo' else unexpected_thai_issue(source,target)):
        raise Problem('这条已保存的译文可能语种有误，请先返回原文重新翻译，再生成学习内容。',422)
    prompt='你是中老双语学习老师。依据给定原文及已有译文，按语义拆成对应的小句，再解释关键词和语法。不得编造原文没有的内容，发现译文错误在note中说明。只输出JSON对象，格式为 {"pairs":[{"lao":"老挝文小句","chinese":"对应中文","words":[{"lao":"关键词","chinese":"词义"}],"note":"简短中文语法或用法说明"}]}。保留老挝文字，不用拼音冒充原文。最多80组，可合并相邻句。每组最多20个关键词。小句拼接必须完整覆盖两种语言各自的文本，不得增删、改写单词；标点和空白可调整。发现错误只写note，不能偷偷改写译文。'
    if phonetics:
        prompt += ('每组增加ipa字段，标注整句老挝语的国际音标IPA；words中每个词也增加ipa字段。'
                   '使用IPA符号及声调标注，不使用汉字谐音或拼音。无法可靠标注时ipa为空字符串，不得猜测。'
                   'ipa为纯字符串，不加斜杠或方括号。不要因音标要求改动lao或chinese文本。')
    if easy_reading:
        prompt += ('每组和每个words词条额外增加romanization和pronunciation_hint两个字符串字段。'
                   'romanization是供初学者使用的拉丁字母辅助读音，不是汉语拼音或官方转写。'
                   '用普通英文字母组合，按音节用空格分开，长元音用双写，送气用h，鼻音ng；不要使用IPA特殊字母、汉字谐音或汉语拼音声调。'
                   '每个音节后标声调箭头：→平、↗升、↘降、↑高、↓低；曲折调可组合箭头。不得把老挝语声调强行简化为普通话四声。'
                   'pronunciation_hint说明该句或词的长短元音、送气、不送气、收尾、声调等实际难点，简短易懂。'
                   '不能确定的注音或提示留空，不得猜测。音标及辅助注音只描述原有老挝文，不改写原文和译文。')
        prompt += 'pronunciation_hint使用'+('老挝语' if explanation_language=='lo' else '简体中文')+'。'
    result=structured_json(chat(config()['daily'],[{'role':'system','content':prompt},{'role':'user','content':json.dumps({'source':source,'translation':target,'direction':direction},ensure_ascii=False)}]))
    pairs=result.get('pairs')
    if not isinstance(pairs,list) or not 1<=len(pairs)<=80:raise Problem('学习拆句数量无效，请缩短内容重试',502)
    cleaned=[]
    for p in pairs:
        if not isinstance(p,dict) or not all(isinstance(p.get(k),str) and 0<len(p[k])<=6000 for k in ('lao','chinese')):raise Problem('学习对照数据无效',502)
        words=p.get('words',[]);note=p.get('note','')
        if not isinstance(note,str) or len(note)>4000 or not isinstance(words,list) or len(words)>20:raise Problem('学习解释格式无效',502)
        if any(not isinstance(w,dict) or not all(isinstance(w.get(k),str) and 0<len(w[k])<=1000 for k in ('lao','chinese')) for w in words):raise Problem('关键词格式无效',502)
        def ipa_value(item):
            value=item.get('ipa','')
            if value is None:return ''
            if not isinstance(value,str) or len(value)>6000:raise Problem('音标格式无效',502)
            return value.strip().strip('/[]').strip()
        item={'lao':p['lao'],'chinese':p['chinese'],'words':[{'lao':w['lao'],'chinese':w['chinese'],**({'ipa':ipa_value(w)} if phonetics else {})} for w in words],'note':note}
        if phonetics:item['ipa']=ipa_value(p)
        if easy_reading:
            def easy_values(value):
                out={}
                for key,limit in (('romanization',6000),('pronunciation_hint',2000)):
                    text=value.get(key,'')
                    if text is None:text=''
                    if not isinstance(text,str) or len(text)>limit:raise Problem('辅助注音格式无效',502)
                    out[key]=text.strip()
                return out
            item.update(easy_values(p))
            for word,original in zip(item['words'],words):word.update(easy_values(original))
        cleaned.append(item)
    def normalized(value):return ''.join(ch for ch in value if ch.isalnum() or '\u0e80'<=ch<='\u0eff')
    lao_reference=source if direction=='lo-zh' else target
    chinese_reference=target if direction=='lo-zh' else source
    if ''.join(normalized(p['lao']) for p in cleaned)!=normalized(lao_reference) or ''.join(normalized(p['chinese']) for p in cleaned)!=normalized(chinese_reference):raise Problem('AI 拆句遗漏或改写了原文，请重试或缩短内容',502)
    return {'pairs':cleaned}

def authenticate(headers):
    token=headers.get('Authorization','').removeprefix('Bearer ')
    with db() as c:
        row=c.execute('SELECT u.* FROM sessions s JOIN users u ON u.name=s.name WHERE s.token=? AND (s.expires=0 OR s.expires>?) AND u.enabled=1',(digest(token),int(time.time()))).fetchone()
    if not row: raise Problem('登录已失效，请重新登录',401)
    return row

def consume(user):
    day=time.strftime('%Y-%m-%d',time.gmtime())
    with db() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('INSERT OR IGNORE INTO usage VALUES(?,?,0)',(user['name'],day))
        n=c.execute('SELECT count FROM usage WHERE name=? AND day=?',(user['name'],day)).fetchone()[0]
        if n>=user['daily_limit']: raise Problem('今日请求额度已用完',429)
        c.execute('UPDATE usage SET count=count+1 WHERE name=? AND day=?',(user['name'],day))

def dispatch(path,data,headers,ip='local',method='POST'):
    if path=='/health': return {'status':'ok'}
    if path.startswith('/admin/'):
        if not ADMIN or not hmac.compare_digest(headers.get('Authorization',''),'Bearer '+ADMIN): raise Problem('管理员口令错误',401)
        if path=='/admin/config':
            cfg=config()
            if method=='PUT':
                feature=data.get('feature')
                if feature not in FEATURES: raise Problem('功能无效')
                item=cfg[feature]
                previous=item.copy()
                for key in ('base_url','model','api_key','voice','provider','region','chinese_voice'):
                    if key in data:
                        if not isinstance(data[key],str) or len(data[key])>2048: raise Problem('配置格式无效')
                        item[key]=data[key].strip()
                parts=urlsplit(item['base_url'])
                if parts.scheme!='https' or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment: raise Problem('模型接口必须为有效 HTTPS 地址')
                if item['provider'] not in ('openai','azure','hub','cloudflare'):raise Problem('服务类型无效')
                if item['provider']=='cloudflare' and feature!='stt':raise Problem('Cloudflare Worker 仅用于语音识别')
                if item['provider']=='cloudflare' and (previous.get('provider')!='cloudflare' or previous.get('base_url')!=item['base_url']) and previous.get('api_key') and not data.get('api_key'):raise Problem('更换到 Cloudflare Worker 时请填写对应的 STT_TOKEN，不会复用其他服务的密钥')
                if item['provider']=='hub' and feature!='tts':raise Problem('此服务类型目前仅用于语音合成')
                if item['provider']=='azure' and feature not in ('tts','stt'):raise Problem('Azure Speech 仅用于语音合成或识别')
                if item['provider']=='azure' and not re.fullmatch(r'[a-z][a-z0-9-]{1,39}',item['region']):raise Problem('Azure 区域无效')
                if not item['model']: raise Problem('模型名称不能为空')
                if 'enabled' in data: item['enabled']=bool(data['enabled'])
                if feature=='stt' and item['enabled']: validate_transcription_service(item)
                save_config(cfg)
            return {f:{k:v for k,v in x.items() if k!='api_key'}|{'key_configured':bool(x['api_key'])} for f,x in cfg.items()}
        if path=='/admin/users':
            with db() as c:
                if method=='POST':
                    name=data.get('name',''); pw=data.get('password',''); limit=data.get('daily_limit',100)
                    if not isinstance(name,str) or not 1<=len(name)<=40 or not isinstance(pw,str) or not 10<=len(pw)<=128 or not isinstance(limit,int) or not 1<=limit<=10000: raise Problem('账号长度 1–40，密码至少 10 字符，额度 1–10000')
                    salt=secrets.token_hex(16)
                    c.execute('INSERT INTO users VALUES(?,?,?,1,?) ON CONFLICT(name) DO UPDATE SET salt=excluded.salt,password=excluded.password,enabled=1,daily_limit=excluded.daily_limit',(name,salt,password(pw,salt),limit))
                    c.execute('DELETE FROM sessions WHERE name=?',(name,))
                if method=='DELETE':
                    c.execute('UPDATE users SET enabled=0 WHERE name=?',(data.get('name'),));c.execute('DELETE FROM sessions WHERE name=?',(data.get('name'),))
                return {'users':[dict(r) for r in c.execute('SELECT name,enabled,daily_limit FROM users')]}
        if path=='/admin/test':
            f=data.get('feature','daily')
            if f not in FEATURES: raise Problem('功能无效')
            if f=='stt':
                validate_transcription_service(config()['stt'])
                raise Problem('语音识别需要实际音频，文字连通测试不能验证。请在 App 录音或导入短音频测试，并分别核对中文和老挝语结果。')
            if f=='tts':
                cfg=config()['tts'];sample='ສະບາຍດີ'
                voice=cfg.get('voice','alloy')
                audio=azure_speech(cfg,sample) if cfg.get('provider') in ('azure','hub') else upstream(cfg,'/audio/speech',{'model':cfg['model'],'input':sample,'voice':voice,'response_format':'mp3'},raw=True)
                return {'text':'老挝语测试音频已生成，请点击播放器试听','audio':base64.b64encode(audio).decode()}
            return {'text':chat(config()[f],[{'role':'user','content':'请回复连接成功'}])}
        raise Problem('接口不存在',404)
    if path=='/login':
        name=data.get('name','');pw=data.get('password','');now=int(time.time())
        if not isinstance(name,str) or not isinstance(pw,str) or len(pw)>128: raise Problem('登录信息无效')
        with db() as c:
            a=c.execute('SELECT * FROM attempts WHERE ip=?',(ip,)).fetchone()
            if a and a['until']>now and a['count']>=8: raise Problem('尝试过多，请十分钟后重试',429)
            c.execute('INSERT INTO attempts VALUES(?,1,?) ON CONFLICT(ip) DO UPDATE SET count=CASE WHEN until<? THEN 1 ELSE count+1 END,until=CASE WHEN until<? THEN ? ELSE until END',(ip,now+600,now,now,now+600))
        with db() as c:
            u=c.execute('SELECT * FROM users WHERE name=? AND enabled=1',(name,)).fetchone()
            expected=password(pw,u['salt'] if u else '00'*16)
            if not u or not hmac.compare_digest(expected,u['password']): raise Problem('账号或密码错误',401)
            token=secrets.token_urlsafe(32)
            c.execute('DELETE FROM sessions WHERE expires>0 AND expires<?',(now,));c.execute('INSERT INTO sessions VALUES(?,?,?)',(digest(token),name,0));c.execute('DELETE FROM attempts WHERE ip=?',(ip,))
        return {'token':token}
    u=authenticate(headers)
    if path=='/service-info':
        # Read-only disclosure for the app. No base URLs, credentials or admin data.
        services={}
        for feature,cfg in config().items():
            if feature not in ('daily','vision','stt','tts'):continue
            provider=cfg.get('provider','openai')
            label={'hub':'Hub API（微软语音兼容）','azure':'Microsoft Azure Speech','cloudflare':'Cloudflare Workers AI · Whisper'}.get(provider,'兼容 OpenAI 格式服务')
            if urlsplit(cfg.get('base_url','')).hostname=='api.deepseek.com':label='DeepSeek 官方服务'
            services[feature]={'provider':label,'model':cfg.get('model','') if provider in ('openai','cloudflare') else '',
                'ready':bool(cfg.get('enabled') and cfg.get('api_key')) and not (feature=='stt' and urlsplit(cfg.get('base_url','')).hostname=='api.deepseek.com')}
            if feature=='tts':
                services[feature]['voice']=cfg.get('voice','')
                services[feature]['chinese_voice']=cfg.get('chinese_voice','') if provider in ('azure','hub') else ''
        return {'services':services,'study_uses':'daily'}
    if path=='/logout':
        with db() as c: c.execute('DELETE FROM sessions WHERE token=?',(digest(headers.get('Authorization','').removeprefix('Bearer ')),))
        return {'ok':True}
    if path not in ('/translate','/image','/stt','/tts','/study'): raise Problem('接口不存在',404)
    if path=='/stt': validate_transcription_service(config()['stt'])
    consume(u)
    if path=='/study':
        source=data.get('source','');target=data.get('translation','');direction=data.get('direction','zh-lo')
        if direction not in ('zh-lo','lo-zh') or not all(isinstance(x,str) and 1<=len(x.strip())<=20000 for x in (source,target)):raise Problem('请提供有效原文与译文（各最多20000字）')
        phonetics=data.get('phonetics',False)
        if not isinstance(phonetics,bool):raise Problem('音标选项无效')
        easy_reading=data.get('easy_reading',False)
        language=data.get('explanation_language','zh')
        if not isinstance(easy_reading,bool) or language not in ('zh','lo'):raise Problem('辅助注音选项无效')
        return study_pairs(source,target,direction,phonetics,easy_reading,language)
    if path=='/translate':
        mode=data.get('mode','daily');text=data.get('text','');direction=data.get('direction','zh-lo')
        if mode not in ('daily','legal','analysis','dictionary') or direction not in ('zh-lo','lo-zh'): raise Problem('任务或语言无效')
        if not isinstance(text,str) or not 1<=len(text.strip())<=20000: raise Problem('请输入 1–20000 字')
        target='老挝语' if direction=='zh-lo' else '简体中文'
        prompts={'daily':'准确翻译至'+target+'，只输出译文。','legal':'法律文本翻译至'+target+'，保留条款结构、数字和术语。不确定的术语须标注，不虚构法条。','analysis':'用中文分析问题，区分事实和推断。不要虚构来源，法律内容提醒专业复核。','dictionary':'提供中老双语释义、词性、例句和用法。不确定时明确说明。这是 AI 辅助释义，不冒充权威词典。'}
        if mode=='daily': return {'translation':translate_daily(config()[mode],text,direction)}
        return {'translation':chat(config()[mode],[{'role':'system','content':prompts[mode]},{'role':'user','content':text}])}
    if path=='/image':
        image=data.get('image','')
        if not isinstance(image,str) or not image.startswith(('data:image/jpeg;base64,','data:image/png;base64,')): raise Problem('请选择 JPEG 或 PNG 图片')
        direction=data.get('direction','lo-zh')
        if direction not in ('zh-lo','lo-zh'):raise Problem('图片翻译方向无效')
        target='中文' if direction=='lo-zh' else '老挝语'
        answer=structured_json(chat(config()['vision'],[{'role':'user','content':[{'type':'text','text':'识别图中文字，翻译成'+target+'。只输出JSON对象：{"source_text":"准确的图片原文","translation":"译文"}。看不清时不要猜测，原文和译文均留空。'},{'type':'image_url','image_url':{'url':image}}]}]))
        source=answer.get('source_text');translation=answer.get('translation')
        if not all(isinstance(x,str) and 1<=len(x.strip())<=20000 for x in (source,translation)):raise Problem('未识别到清晰原文或译文，请换一张图片',502)
        return {'source_text':source,'translation':translation}
    if path=='/tts':
        text=data.get('text','')
        if not isinstance(text,str) or not 1<=len(text)<=3000: raise Problem('朗读文字限制 3000 字')
        language=data.get('language','auto')
        if language not in ('auto','lo','zh'):raise Problem('朗读语言仅支持 auto、lo 或 zh')
        cfg=config()['tts']; voice=cfg.get('voice','alloy')
        audio=azure_speech(cfg,text,language) if cfg.get('provider') in ('azure','hub') else upstream(cfg,'/audio/speech',{'model':cfg['model'],'input':text,'voice':voice,'response_format':'mp3'},raw=True)
        return {'audio':base64.b64encode(audio).decode()}
    try: audio=base64.b64decode(data.get('audio',''),validate=True)
    except (ValueError,TypeError): raise Problem('录音格式无效')
    if not audio: raise Problem('录音为空')
    if len(audio)>5*1024*1024:raise Problem('音频最大 5 MiB',413)
    language=data.get('language','auto')
    if language not in ('auto','zh','lo'):raise Problem('识别语言仅支持中文 zh、老挝语 lo 或自动 auto')
    fmt=data.get('format','m4a')
    if fmt not in ('m4a','mp3','wav'):raise Problem('不支持的音频格式')
    mime={'m4a':'audio/mp4','mp3':'audio/mpeg','wav':'audio/wav'}[fmt]
    cfg=config()['stt']
    if cfg.get('provider')=='azure': return azure_transcribe(cfg,audio,language,fmt)
    boundary=secrets.token_hex(16)
    language_field='' if language=='auto' else f'--{boundary}\r\nContent-Disposition: form-data; name="language"\r\n\r\n{language}\r\n'
    body=(language_field+f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{cfg["model"]}\r\n--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="recording.{fmt}"\r\nContent-Type: {mime}\r\n\r\n').encode()+audio+f'\r\n--{boundary}--\r\n'.encode()
    r=upstream(cfg,'/audio/transcriptions',{},body=body,content_type='multipart/form-data; boundary='+boundary)
    text=r.get('text')
    if not isinstance(text,str) or not text.strip():raise Problem('未识别到文字，请检查音频音量、格式与所选语言',502)
    return {'text':text.strip()}

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def handle_request(self):
        path=urlsplit(self.path).path
        try:
            if self.command in ('GET','HEAD') and path=='/app':
                self.send_response(308);self.send_header('Location','/app/');self.send_header('Content-Length','0');self.end_headers();return
            if self.command in ('GET','HEAD') and path.startswith('/app/'):
                relative=path[len('/app/'): ] or 'index.html'
                allowed={'index.html','i18n.js','app.js','style.css','sw.js','manifest.webmanifest','assets/icon.svg','assets/icon-192.png','assets/icon-512.png','assets/conversation.png','assets/study.png'}
                if relative not in allowed:raise Problem('页面不存在',404)
                file=Path(__file__).parent/'web'/relative
                if not file.is_file():raise Problem('网页文件尚未上传完整',404)
                body=file.read_bytes()
                mime={'js':'application/javascript','webmanifest':'application/manifest+json','svg':'image/svg+xml'}.get(file.suffix.lstrip('.'),mimetypes.guess_type(file.name)[0] or 'application/octet-stream')
                self.send_response(200);self.send_header('Content-Type',mime+('; charset=utf-8' if mime.startswith('text/') or mime in ('application/javascript','application/manifest+json') else ''))
                self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-cache');self.send_header('X-Content-Type-Options','nosniff');self.send_header('Referrer-Policy','same-origin')
                self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'")
                self.end_headers()
                if self.command!='HEAD':self.wfile.write(body)
                return
            if self.command=='GET' and path in ('/','/admin'):
                body=(Path(__file__).parent/'static/admin.html').read_bytes();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body);return
            size=int(self.headers.get('Content-Length','0'))
            if size<0 or size>8*1024*1024: raise Problem('请求过大',413)
            data=json.loads(self.rfile.read(size)) if size else {}
            if not isinstance(data,dict): raise Problem('请求格式无效')
            result=dispatch(path,data,self.headers,self.client_address[0],self.command);status=200
        except Problem as e: result={'error':e.message};status=e.status
        except (ValueError,UnicodeError): result={'error':'请求格式无效'};status=400
        except Exception: result={'error':'服务器内部错误'};status=500
        raw=json.dumps(result,ensure_ascii=False).encode();self.send_response(status);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(raw)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(raw)
    do_GET=do_HEAD=do_POST=do_PUT=do_DELETE=handle_request
    def setup(self):
        super().setup();self.connection.settimeout(130)

if __name__=='__main__':
    if len(ADMIN)<24: raise SystemExit('LAOLINGO_ADMIN_TOKEN 必须至少 24 字符')
    init();ThreadingHTTPServer(('127.0.0.1',int(os.environ.get('PORT','8080'))),Handler).serve_forever()
