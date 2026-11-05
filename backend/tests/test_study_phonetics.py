import copy, importlib.util, json, os, pathlib, tempfile, unittest
from unittest.mock import patch
TMP = tempfile.TemporaryDirectory()
os.environ['LAOLINGO_DATA'] = TMP.name
spec = importlib.util.spec_from_file_location('study_service', pathlib.Path(__file__).resolve().parents[1] / 'app.py')
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)

class StudyPhoneticsTests(unittest.TestCase):
 def setUp(self):
  self.result={'pairs':[{'lao':'ດີ','chinese':'好','ipa':'/diː˧/','words':[{'lao':'ດີ','chinese':'好','ipa':'[diː˧]'}],'note':'形容词'}]}
 def generate(self, result=None, direction='zh-lo', enabled=True):
  with patch.object(s,'config',return_value={'daily':{}}), patch.object(s,'chat',return_value=json.dumps(result or self.result)) as chat:
   answer=s.study_pairs('好' if direction=='zh-lo' else 'ດີ','ດີ' if direction=='zh-lo' else '好',direction,enabled)
   if enabled:self.assertIn('国际音标IPA',chat.call_args.args[1][0]['content'])
   return answer['pairs'][0]
 def test_sentence_and_word_ipa_survive_validation(self):
  p=self.generate();self.assertEqual(p['ipa'],'diː˧');self.assertEqual(p['words'][0]['ipa'],'diː˧')
 def test_reverse_translation_has_lao_ipa(self):
  self.assertEqual(self.generate(direction='lo-zh')['ipa'],'diː˧')
 def test_missing_ipa_keeps_old_responses_readable(self):
  r=copy.deepcopy(self.result);del r['pairs'][0]['ipa'];del r['pairs'][0]['words'][0]['ipa']
  self.assertEqual(self.generate(r)['ipa'],'')
 def test_old_clients_keep_previous_shape(self):
  p=self.generate(enabled=False);self.assertNotIn('ipa',p);self.assertNotIn('ipa',p['words'][0])
 def test_invalid_ipa_rejected(self):
  for bad in ([],{},123,'x'*6001):
   r=copy.deepcopy(self.result);r['pairs'][0]['ipa']=bad
   with self.assertRaises(s.Problem):self.generate(r)
 def test_ipa_does_not_bypass_text_coverage(self):
  r=copy.deepcopy(self.result);r['pairs'][0]['lao']='ສະບາຍດີ'
  with self.assertRaises(s.Problem):self.generate(r)
