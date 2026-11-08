"""Regression coverage for descriptive application identity and safe HTTP diagnostics."""
import importlib.util
import io
import json
from pathlib import Path
import urllib.error
import unittest
from unittest import mock

P=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('client_http_tests',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
TOKEN='d'*64
LINK='https://mesh.example.test/join/'+TOKEN
PAYLOAD=dict(format='easytier-cf-join-v1',domain='mesh.example.test',network='test',secret='s'*54,subnet='10.66.66.0/24',server_name='vps')


class ClientHTTPTests(unittest.TestCase):
    def test_descriptive_application_identity_and_post_protocol(self):
        response=mock.MagicMock();response.__enter__.return_value.read.return_value=json.dumps(PAYLOAD).encode()
        opener=mock.Mock();opener.open.return_value=response
        with mock.patch.object(m.urllib.request,'build_opener',return_value=opener):
            self.assertEqual(m.fetch_join_link(LINK),PAYLOAD)
        request=opener.open.call_args.args[0]
        self.assertEqual(request.method,'POST');self.assertEqual(request.data,b'')
        self.assertEqual(request.get_header('User-agent'),m.HTTP_USER_AGENT)
        self.assertTrue(m.HTTP_USER_AGENT.startswith('easytier-easy/'))
        self.assertNotIn('Python-urllib',m.HTTP_USER_AGENT)
        self.assertNotIn('Mozilla',m.HTTP_USER_AGENT)
        self.assertEqual(request.get_header('Accept'),'application/json')
        self.assertEqual(request.get_header('X-easytier-join'),'1')
        self.assertEqual(opener.open.call_args.kwargs['timeout'],25)

    def error_case(self,body=b'',headers=None):
        source=io.BytesIO(body)
        error=urllib.error.HTTPError(LINK,403,'Forbidden',headers or {},source)
        opener=mock.Mock();opener.open.side_effect=error
        with mock.patch.object(m.urllib.request,'build_opener',return_value=opener),self.assertRaises(m.SetupError) as caught:
            m.fetch_join_link(LINK)
        message=str(caught.exception)
        self.assertNotIn(TOKEN,message);self.assertNotIn(PAYLOAD['secret'],message)
        self.assertNotIn(LINK,message)
        return message,source.tell()

    def test_plain_1010_is_distinguished_and_does_not_echo_body(self):
        message,_=self.error_case(b'error code: 1010\n'+TOKEN.encode()+PAYLOAD['secret'].encode(),{'CF-Ray':'abc123-SIN'})
        self.assertIn('1010',message);self.assertIn('Browser Integrity Check',message)
        self.assertIn('abc123-SIN',message);self.assertIn('更新客户端',message)

    def test_html_1010_is_distinguished(self):
        message,_=self.error_case(b'<html><h1>Error 1010</h1></html>')
        self.assertIn('1010',message)

    def test_generic_403_is_not_automatically_called_waf(self):
        message,_=self.error_case(b'custom origin forbidden')
        self.assertIn('HTTP 403',message);self.assertNotIn('WAF',message)
        self.assertNotIn('1010',message)

    def test_challenge_response_is_distinguished(self):
        message,_=self.error_case(b'<html>challenge</html>',{'cf-mitigated':'challenge'})
        self.assertIn('人机挑战',message);self.assertNotIn('1010',message)

    def test_error_read_is_bounded_and_rejects_unsafe_ray_id(self):
        body=b'x'*16384+b'error code: 1010 '+TOKEN.encode()
        message,read=self.error_case(body,{'CF-Ray':'bad\nvalue'})
        self.assertEqual(read,16384);self.assertNotIn('1010',message)
        self.assertNotIn('bad',message);self.assertNotIn('Ray ID',message)

    def test_empty_200_is_not_accepted_as_credentials(self):
        response=mock.MagicMock();response.__enter__.return_value.read.return_value=b' \r\n'
        opener=mock.Mock();opener.open.return_value=response
        with mock.patch.object(m.urllib.request,'build_opener',return_value=opener),self.assertRaises(m.SetupError) as caught:
            m.fetch_join_link(LINK)
        self.assertIn('200',str(caught.exception));self.assertIn('响应为空',str(caught.exception))
        self.assertNotIn(TOKEN,str(caught.exception))


if __name__=='__main__':unittest.main()
