# Velt

Instalador automático para o [VeltrixUPGW](https://github.com/TelksBr/VeltrixUPGW) — um gateway UDP standalone escrito em Go, compatível com o protocolo **BadVPN udpgw**. Ele deixa tudo pronto na sua VPS em um único comando: compila o binário, sobe como serviço, libera as portas no firewall e instala um painel de controle.

## O que o script faz

- ✅ Instala dependências (`git`, `curl`, build tools) e o **Go** automaticamente, se necessário
- ✅ Clona e compila o VeltrixUPGW direto do código-fonte
- ✅ Cria um serviço **systemd** que inicia com o servidor e reinicia sozinho se cair
- ✅ Libera a porta TCP de escuta e uma faixa de portas UDP no firewall (`ufw`, `firewalld` ou `iptables`)
- ✅ Instala o comando **`Upg`** — um painel interativo pra gerenciar tudo depois da instalação

## Requisitos

- VPS com Debian/Ubuntu ou CentOS/Fedora
- Acesso root (ou `sudo`)
- Conexão com a internet

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/Willapela/Velt/main/install.sh -o install.sh
sudo bash install.sh
```

Durante a instalação, o script pergunta:

| Pergunta | Padrão |
|---|---|
| Porta TCP de escuta do gateway | `7400` |
| Faixa de portas UDP a liberar no firewall | `10000-60000` |
| Nome do comando do painel | `Upg` |

Pode apertar `ENTER` em todas para usar os valores padrão.

## Usando o painel (`Upg`)

Depois de instalado, basta digitar em qualquer sessão SSH:

```bash
Upg
```

Isso abre um menu com as opções:

1. Ver status do serviço
2. Iniciar serviço
3. Parar serviço
4. Reiniciar serviço
5. Ver logs em tempo real
6. Ver configuração atual
7. Trocar porta TCP de escuta
8. **Abrir mais portas UDP no firewall**
9. Desinstalar
0. Sair

## Arquivos criados na VPS

| Caminho | Descrição |
|---|---|
| `/usr/local/bin/veltrixupgw` | Binário compilado do gateway |
| `/usr/local/bin/Upg` | Script do painel de gerenciamento |
| `/etc/veltrixupgw/veltrixupgw.env` | Arquivo de configuração (porta, timeouts, etc.) |
| `/etc/systemd/system/veltrixupgw.service` | Unit do systemd |
| `/opt/veltrixupgw` | Código-fonte usado na compilação |

## Comandos úteis (fora do painel)

```bash
# status do serviço
systemctl status veltrixupgw

# logs em tempo real
journalctl -u veltrixupgw -f

# reiniciar
systemctl restart veltrixupgw
```

## Desinstalar

Pelo painel: `Upg` → opção `9`.

Manual:

```bash
sudo systemctl stop veltrixupgw
sudo systemctl disable veltrixupgw
sudo rm -f /etc/systemd/system/veltrixupgw.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/veltrixupgw /usr/local/bin/Upg
sudo rm -rf /etc/veltrixupgw /opt/veltrixupgw
```

## Créditos

- Servidor UDP gateway: [TelksBr/VeltrixUPGW](https://github.com/TelksBr/VeltrixUPGW)
- Instalador e painel: este repositório

## Licença

Consulte os termos do projeto original ([VeltrixUPGW](https://github.com/TelksBr/VeltrixUPGW)) e deste repositório.
