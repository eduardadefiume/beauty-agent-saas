import type { Metadata } from 'next';

import styles from '../privacidade/politica.module.css';

// AS INSTRUÇÕES DE EXCLUSÃO DE DADOS SÃO UMA PÁGINA SEPARADA PORQUE A META
// EXIGE UMA URL SÓ PARA ELAS.
//
// E porque quem chega aqui não quer ler política: quer saber o que fazer para
// sumir. Então a página começa pelo passo a passo e só depois explica o
// resto.
//
// O endereço antigo apontava para um projeto do Supabase que está pausado.
// Aqui não depende de projeto nenhum estar acordado.

export const metadata: Metadata = {
  title: 'Exclusão de dados — Beauty Agent SaaS',
  description:
    'Como solicitar a exclusão dos seus dados pessoais tratados pelo Beauty Agent SaaS, e o que acontece depois do pedido.',
};

export const dynamic = 'force-static';

const ASSUNTO = 'Exclusão de dados - Beauty Agent SaaS';

export default function ExclusaoDeDados() {
  return (
    <div className={styles.pagina}>
      <main className={styles.folha}>
        <h1>Exclusão de dados</h1>
        <p className={styles.meta}>
          <strong>Beauty Agent SaaS</strong> · Última atualização: 16 de setembro de 2026
        </p>

        <p className={styles.aviso}>
          Você pode pedir a exclusão dos seus dados a qualquer momento, sem precisar justificar. O
          pedido é gratuito.
        </p>

        <h2>Como pedir</h2>
        <ol className={styles.passos}>
          <li>
            Envie um e-mail para{' '}
            <a
              href={`mailto:eddigital.oficial@gmail.com?subject=${encodeURIComponent(ASSUNTO)}`}
            >
              eddigital.oficial@gmail.com
            </a>{' '}
            com o assunto <strong>“Exclusão de dados — Beauty Agent SaaS”</strong>.
          </li>
          <li>
            Informe o <strong>número de telefone</strong> que você usou para conversar com o
            atendimento, e o <strong>nome do salão ou estabelecimento</strong>. É só isso que
            precisamos para localizar os seus dados — não envie documento, foto ou qualquer
            informação a mais.
          </li>
          <li>
            Podemos pedir uma confirmação simples de que o número é seu. Isso existe para impedir
            que outra pessoa apague os seus dados, ou acesse o que é seu.
          </li>
        </ol>

        <h2>O que acontece depois</h2>
        <p>
          Confirmada a identidade, apagamos as suas conversas, a sua ficha e os seus dados de
          contato dos nossos sistemas. Respondemos confirmando o que foi apagado.
        </p>
        <p>
          Quando o atendimento aconteceu em nome de um salão, o salão é o controlador dos seus
          dados: encaminhamos o pedido a ele e ele também precisa apagar o que mantiver por conta
          própria. Avisamos você quando isso for o caso.
        </p>

        <h2>O que pode continuar guardado, e por quê</h2>
        <ul>
          <li>
            <strong>Registros que a lei obriga a manter</strong>, como comprovantes fiscais de um
            atendimento que aconteceu. Esses ficam pelo prazo legal e não são usados para falar com
            você.
          </li>
          <li>
            <strong>Registros técnicos mínimos</strong> de segurança e auditoria, que guardam que
            uma ação aconteceu — sem o conteúdo das suas mensagens.
          </li>
          <li>
            <strong>A sua conversa no seu próprio WhatsApp.</strong> Ela é sua e do salão, está no
            aparelho de vocês, e apagar aqui não apaga lá.
          </li>
        </ul>

        <h2>Prazo</h2>
        <p>
          Respondemos o mais rápido possível e, em qualquer caso, dentro dos prazos previstos na
          LGPD. Se houver qualquer motivo para não apagar alguma coisa, dizemos qual é o motivo, em
          português claro.
        </p>

        <footer className={styles.rodape}>
          Política completa em <a href="/privacidade">privacidade</a> · Canal de privacidade:{' '}
          <a href="mailto:eddigital.oficial@gmail.com">eddigital.oficial@gmail.com</a>
        </footer>
      </main>
    </div>
  );
}
