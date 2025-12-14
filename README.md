# Proxym-Easy

> [!Caution]
> 禁止任何形式的转载或发布至🇨🇳大陆平台
>
> Any form of reprinting or posting to the 🇨🇳 mainland platform is prohibited

> [!WARNING]
> 中国大陆用户使用请遵守本国法律法规
>
> Mainland China users please abide by the laws and regulations of your country.
>

## 免责申明/Disclaimer

> [!IMPORTANT]
> 任何以任何方式查看此项目的人或直接或间接使用该项目的使用者都应仔细阅读此声明。
>
> 保留随时更改或补充此免责声明的权利。
>
> 一旦使用并复制了该项目的任何文件，则视为您已接受此免责声明。
>
> Anyone who views this project in any way or uses it directly or indirectly should read this statement carefully.
>
> We reserve the right to change or supplement this disclaimer at any time.
>
> Once you use and copy any file of this project, you are deemed to have accepted this disclaimer.

- 本项目涉及的文件仅用于资源共享和学习研究，不能保证其合法性，准确性，完整性和有效性，请根据情况自行判断.

- 请勿将本项目的任何内容用于商业或非法目的

***通过xray实现对？？？节点服务端的支持***
### 1. 安装
```
curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/vless-encryption.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy /usr/local/bin/proxym-easy && sudo proxym-easy
```
### 2. 已安装？执行
```
sudo proxym-easy
```
### 3. 卸载
##### 卸载选项在脚本中已提供
***Tips***
>
URI保存在本机
```
/etc/proxym/vless.json
```
配置文件保存在本机
```
/usr/local/etc/xray/config.json
```
重置uuid及密码
```
sudo proxym-easy reset
```
>
VLESS Encryption与VLESS Version Reality***无法同时启用***当你选择VLESS Version Reality那么前面生成的VLESS Encryption相关内容***不会生效***
>
若使用
VLESS Encryption+ws+tls传输推荐搭配[Cert-Easy](https://github.com/Lanlan13-14/Cert-Easy)使用，可实现仅输入域名后自动填充相关内容
>
Reality域名选择推荐
[点击查看](https://www.v2ray-agent.com/archives/1689439383686)
>
部分功能解答(可选)
[点击查看](https://github.com/Lanlan13-14/Proxym-Easy/blob/main/script%2Fworker.md)
>
***2025.10.6更新***
>
1.修复proxym-easy reset后遇到的bug
>
2.worker代码返回节点以SERVER_TOKENS顺序排序
> ***Tips***
>本次更新为破坏式更新请重新执行代码
3.decryption生成存在错误（之后修复