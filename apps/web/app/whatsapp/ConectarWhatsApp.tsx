'use client';

import { useCallback, useEffect, useRef, useState } from 'react';

import styles from './whatsapp.module.css';

// O BOTÃO QUE CONECTA O WHATSAPP DO SALÃO.
//
// É por aqui que um salão entra no produto. O dono clica, digita o número
// dele, recebe um código no WhatsApp, LÊ UM QR CODE dentro do aplicativo
// WhatsApp Business e aceita compartilhar o histórico. A partir daí a Meta
// entrega as conversas dos últimos meses para o nosso webhook, e o agente
// aprende com o que o salão já fazia -- em vez de aprender errando na frente
// de uma cliente.
//
// `featureType: whatsapp_business_app_onboarding` é o que muda tudo: é ele que
// pede a Coexistência, onde o número continua funcionando no aplicativo do
// dono E na API ao mesmo tempo. Sem isso o fluxo conecta um número novo e o
// histórico não vem.
//
// O QUE VOLTA PARA CÁ, E O QUE NÃO VOLTA. Voltam duas coisas: um CÓDIGO, pelo
// callback do login, e o par WABA + número, por uma mensagem que a janela da
// Meta envia. Código não serve para nada sozinho -- quem troca por token é o
// servidor, com o segredo do app que nunca chega ao navegador. Token nenhum
// passa por esta tela.
//
// A JANELA DE 24 HORAS. Depois que o dono conclui, a Meta dá 24 horas para
// sincronizar o histórico. Por isso a troca acontece na hora, no mesmo clique,
// e não numa tela de "confirme depois".

const APP_ID = process.env.NEXT_PUBLIC_META_APP_ID ?? '1580552073741431';
const CONFIG_ID = process.env.NEXT_PUBLIC_META_CONFIG_ID ?? '1382497443998562';
const GRAPH_VERSION = 'v21.0';

type DadosDoSignup = { waba_id?: string; phone_number_id?: string };

type Resultado = {
  numero?: string | null;
  nomeVerificado?: string | null;
  coexistencia?: boolean;
  historico?: string;
};

declare global {
  interface Window {
    FB?: {
      init: (opcoes: Record<string, unknown>) => void;
      login: (
        cb: (resposta: { authResponse?: { code?: string } }) => void,
        opcoes: Record<string, unknown>
      ) => void;
    };
    fbAsyncInit?: () => void;
  }
}

export function ConectarWhatsApp({ tenantId }: { tenantId: string }) {
  const [sdkPronto, setSdkPronto] = useState(false);
  const [ocupado, setOcupado] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [resultado, setResultado] = useState<Resultado | null>(null);

  // O que a janela da Meta contou, guardado fora do React: a mensagem chega
  // antes do callback do login, e um estado que re-renderiza chegaria tarde.
  const doSignup = useRef<DadosDoSignup>({});
  const consentiuHistorico = useRef<boolean | null>(null);

  useEffect(() => {
    if (window.FB) {
      setSdkPronto(true);
      return;
    }

    window.fbAsyncInit = () => {
      window.FB?.init({ appId: APP_ID, cookie: true, xfbml: false, version: GRAPH_VERSION });
      setSdkPronto(true);
    };

    const script = document.createElement('script');
    script.src = 'https://connect.facebook.net/pt_BR/sdk.js';
    script.async = true;
    script.defer = true;
    script.crossOrigin = 'anonymous';
    document.body.appendChild(script);
  }, []);

  useEffect(() => {
    function ouvir(evento: MessageEvent) {
      // Só a Meta fala aqui. Sem esta linha, qualquer página aberta em outra
      // aba poderia mandar um waba_id e nos fazer conectar o salão errado.
      if (
        evento.origin !== 'https://www.facebook.com' &&
        evento.origin !== 'https://web.facebook.com'
      ) {
        return;
      }
      try {
        const dados = JSON.parse(String(evento.data)) as {
          type?: string;
          event?: string;
          data?: DadosDoSignup & { consent?: string };
        };
        if (dados.type !== 'WA_EMBEDDED_SIGNUP') return;

        if (dados.event === 'FINISH' && dados.data) {
          doSignup.current = dados.data;
          // O consentimento do histórico, quando a Meta manda, é o que decide
          // se as conversas vêm. Quando não manda, fica indefinido -- e supor
          // que o dono aceitou seria mentir para a tela dele.
          if (typeof dados.data.consent === 'string') {
            consentiuHistorico.current = dados.data.consent.toUpperCase().includes('GRANT');
          }
        }
        if (dados.event === 'CANCEL') {
          setErro('Você fechou a janela antes de concluir. Nada foi conectado.');
        }
      } catch {
        // Mensagem que não é JSON não é do fluxo. Ignorar é o certo.
      }
    }

    window.addEventListener('message', ouvir);
    return () => window.removeEventListener('message', ouvir);
  }, []);

  const conectar = useCallback(() => {
    if (!window.FB || ocupado) return;
    setErro(null);
    setResultado(null);
    doSignup.current = {};
    consentiuHistorico.current = null;
    setOcupado(true);

    window.FB.login(
      async (resposta) => {
        const code = resposta?.authResponse?.code;
        if (!code) {
          setOcupado(false);
          setErro('A Meta não devolveu o código. Nada foi conectado.');
          return;
        }

        try {
          const r = await fetch('/api/whatsapp', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              action: 'conectarWhatsApp',
              tenantId,
              code,
              wabaId: doSignup.current.waba_id,
              phoneNumberId: doSignup.current.phone_number_id,
              historicoConsentido: consentiuHistorico.current,
            }),
          });
          const corpo = (await r.json()) as Resultado & { error?: string };
          if (!r.ok) {
            setErro(corpo?.error ?? 'Não consegui concluir a conexão.');
            return;
          }
          setResultado(corpo);
        } catch {
          setErro('Não consegui falar com o servidor para concluir a conexão.');
        } finally {
          setOcupado(false);
        }
      },
      {
        config_id: CONFIG_ID,
        response_type: 'code',
        override_default_response_type: true,
        extras: {
          setup: {},
          featureType: 'whatsapp_business_app_onboarding',
          sessionInfoVersion: '3',
        },
      }
    );
  }, [ocupado, tenantId]);

  return (
    <div className={styles.conectar}>
      <button
        type="button"
        className={styles.botaoConectar}
        onClick={conectar}
        disabled={!sdkPronto || ocupado}
      >
        {ocupado ? 'Conectando…' : 'Conectar o WhatsApp do salão'}
      </button>

      {!sdkPronto && <span className={styles.conectarNota}>carregando o login da Meta…</span>}

      {erro && <span className={styles.pillAlerta}>{erro}</span>}

      {resultado && (
        <span className={styles.conectarNota}>
          Conectado: {resultado.numero ?? 'número'}
          {resultado.nomeVerificado ? ` (${resultado.nomeVerificado})` : ''}.{' '}
          {resultado.coexistencia
            ? 'O número continua funcionando no aplicativo do dono.'
            : 'Este número atende só pela API.'}{' '}
          {resultado.historico === 'CONSENTIDO'
            ? 'O histórico das conversas foi liberado e começa a chegar.'
            : resultado.historico === 'RECUSADO'
              ? 'O histórico não foi liberado.'
              : 'Sem informação sobre o histórico.'}
        </span>
      )}
    </div>
  );
}
