import importlib.util, os, pathlib, tempfile, unittest
from unittest.mock import patch
TMP = tempfile.TemporaryDirectory()
os.environ['LAOLINGO_DATA'] = TMP.name
spec = importlib.util.spec_from_file_location('tts_service', pathlib.Path(__file__).resolve().parents[1] / 'app.py')
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)

class Response:
 def __enter__(self): return self
 def __exit__(self, *args): pass
 def read(self, *args): return b'mp3'

class SpeechLanguageTests(unittest.TestCase):
 def setUp(self):
  self.cfg = {'enabled': True, 'api_key': 'test', 'provider': 'azure', 'region': 'eastus2', 'voice': 'lo-LA-KeomanyNeural', 'chinese_voice': 'zh-CN-XiaoxiaoNeural'}
 def request(self, text, language):
  with patch.object(s.urllib.request, 'build_opener') as opener:
   opener.return_value.open.return_value = Response()
   s.azure_speech(self.cfg, text, language)
   return opener.return_value.open.call_args.args[0].data.decode()
 def test_same_number_uses_selected_language(self):
  lao = self.request('20', 'lo'); chinese = self.request('20', 'zh')
  self.assertIn('lo-LA-KeomanyNeural', lao); self.assertIn('xml:lang="lo-LA"', lao)
  self.assertIn('zh-CN-XiaoxiaoNeural', chinese); self.assertIn('xml:lang="zh-CN"', chinese)
 def test_old_clients_keep_automatic_detection(self):
  self.assertIn('lo-LA-KeomanyNeural', self.request('ສະບາຍດີ', 'auto'))
  self.assertIn('zh-CN-XiaoxiaoNeural', self.request('20', 'auto'))
 def test_invalid_language_rejected(self):
  with self.assertRaises(s.Problem): s.azure_speech(self.cfg, '20', 'th')
