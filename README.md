# Binance AI Trader — TEdgeBrowser Edition

## Visão Geral

Aplicativo desktop Delphi com **interface moderna HTML/CSS/JS** renderizada via **TEdgeBrowser** (WebView2). O backend Delphi comunica com a Binance API e LLMs, enquanto o frontend exibe um dashboard de trading profissional com tema escuro.

---

## 📐 Arquitetura

```
┌─────────────────────────────────────────────────────┐
│                    TEdgeBrowser                      │
│  ┌───────────────────────────────────────────────┐  │
│  │         HTML / CSS / JS  (index.html)         │  │
│  │  Dashboard │ Configurações │ Log │ Histórico  │  │
│  └──────────────────┬────────────────────────────┘  │
│                     │ WebMessage (JSON)              │
│  ┌──────────────────┴────────────────────────────┐  │
│  │           Delphi Backend (uMain.pas)          │  │
│  │  ┌─────────┐  ┌──────────┐  ┌─────────────┐  │  │
│  │  │ Binance │  │ Technical│  │  AI Engine   │  │  │
│  │  │   API   │  │ Analysis │  │ (OpenAI/etc) │  │  │
│  │  └─────────┘  └──────────┘  └─────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Comunicação Bidirecional

| Direção | Mecanismo | Formato |
|---------|-----------|---------|
| **JS → Delphi** | `window.chrome.webview.postMessage(json)` | `{ action, data }` |
| **Delphi → JS** | `FEdge.ExecuteScript('handleDelphiMessage(...)')` | `{ action, data }` |

### Actions JS → Delphi
- `pageReady` — Página carregou, envia config inicial
- `analyze` — Solicita análise técnica + IA
- `buy` / `sell` — Executa ordem de compra/venda
- `startBot` / `stopBot` — Controla o bot automático
- `testConnection` — Testa conexão com Binance
- `saveConfig` — Salva configurações

### Actions Delphi → JS
- `updatePrice` — Atualiza preço em tempo real
- `updateIndicators` — Envia RSI, MACD, Bollinger, etc.
- `updateSignal` — Envia sinal da IA (BUY/SELL/HOLD)
- `updateBalance` — Atualiza saldo da conta
- `updateCandles` — Dados para o mini-gráfico
- `addLog` — Adiciona entrada no log
- `addTrade` — Adiciona trade ao histórico
- `connectionStatus` — Status de conexão
- `botStatus` — Status do bot
- `analyzing` — Overlay de loading
- `loadConfig` — Carrega config salva

---

## 📁 Estrutura

```
BinanceTrader/
├── html/
│   └── index.html           ← Interface completa (HTML/CSS/JS single-file)
├── src/
│   ├── BinanceTrader.dpr    ← Projeto Delphi
│   ├── uMain.pas / .dfm     ← Form principal + TEdgeBrowser bridge
│   ├── uBinanceAPI.pas       ← Cliente REST Binance (HMAC-SHA256)
│   ├── uTechnicalAnalysis.pas← Indicadores técnicos
│   ├── uAIEngine.pas         ← Motor de IA (OpenAI-compatible)
│   └── uTypes.pas            ← Types compartilhados
└── README.md
```

---

## 🔧 Requisitos

- **Delphi 10.4+ Sydney** (precisa de `Vcl.Edge` / TEdgeBrowser)
- **WebView2 Runtime** instalado (Windows 10/11 já inclui)
- Sem componentes de terceiros

---

## 🚀 Como Usar

1. Abra `BinanceTrader.dpr` no Delphi
2. Compile (F9)
3. Certifique que `html/index.html` está na pasta do executável
4. Execute o app
5. Vá em **Configurações**:
   - Cole suas chaves da Binance (use Testnet!)
   - Cole sua API Key de IA (OpenAI, Anthropic, DeepSeek...)
   - Configure par, intervalo e parâmetros
   - Salve
6. Volte ao **Dashboard** e clique **Analisar Agora**

---

## 🎨 Interface

O frontend possui:

- **Dashboard** — Preço em tempo real, indicadores técnicos com cards coloridos, mini-gráfico canvas, painel de sinais da IA com confidence bar, controles de trading, saldo e controle do bot
- **Configurações** — API Keys, modelo de IA, parâmetros de trading com toggles modernos
- **Log** — Log estilo terminal com tags coloridas por categoria
- **Histórico** — Tabela de trades com badges coloridos

### Design
- Tema escuro profissional (estilo Binance/TradingView)
- Gradientes sutis e efeitos de glow
- Animações CSS (pulse, fadeIn, hover effects)
- Mini-gráfico de preço via Canvas API
- Responsivo para diferentes tamanhos de janela

---

## ⚠️ Avisos

1. **USE TESTNET** para testes — nunca teste com dinheiro real
2. **IA não é garantia** de lucro
3. Monitore o bot mesmo em modo automático
4. Nunca compartilhe suas API Keys
5. Este software é **educacional**
