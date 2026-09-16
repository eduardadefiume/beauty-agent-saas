import type { Metadata } from 'next';

import styles from './politica.module.css';

// A POLÍTICA DE PRIVACIDADE SAI DO SUPABASE E VEM PARA O DOMÍNIO.
//
// Ela morava numa edge function, e a URL cadastrada na Meta apontava para o
// projeto `agente-beleza-saas-prod-sp` -- que está PAUSADO. Ou seja: a
// política de privacidade do app estava fora do ar, e a Revisão do App da
// Meta confere essa URL. Isso reprovaria o pedido de permissão que destrava o
// Embedded Signup, e ninguém tinha visto.
//
// Aqui ela não depende de qual projeto do Supabase está acordado: é página do
// site, no domínio do negócio, estática, sem sessão e sem JavaScript.
//
// O TEXTO É O MESMO, palavra por palavra, e a data de atualização continua a
// da última vez que ele mudou de verdade. Mudou o endereço, não a política.

export const metadata: Metadata = {
  title: 'Política de Privacidade — Beauty Agent SaaS',
  description:
    'Como tratamos dados pessoais no atendimento automatizado e nos agendamentos para negócios de beleza, inclusive por WhatsApp.',
};

export const dynamic = 'force-static';

export default function PoliticaDePrivacidade() {
  return (
    <div className={styles.pagina}>
      <main className={styles.folha}>
        <h1>Política de Privacidade</h1>
        <p className={styles.meta}>
          <strong>Beauty Agent SaaS</strong> · Última atualização: 5 de agosto de 2026
        </p>

        <p className={styles.aviso}>
          Esta política explica como tratamos dados pessoais ao oferecer atendimento automatizado e
          agendamentos para negócios de beleza, inclusive por WhatsApp.
        </p>

        <h2>1. Quem somos e nossos papéis</h2>
        <p>
          O Beauty Agent SaaS é uma plataforma de atendimento e agendamento assistidos por
          inteligência artificial. Para os dados de clientes finais tratados em nome de salões,
          clínicas e outros negócios assinantes, o negócio contratante atua como controlador e o
          Beauty Agent SaaS atua como operador. Para dados de cadastro, segurança, suporte e
          relacionamento dos próprios usuários da plataforma, o Beauty Agent SaaS pode atuar como
          controlador.
        </p>

        <h2>2. Dados que podemos tratar</h2>
        <ul>
          <li>dados de identificação e contato, como nome, telefone e e-mail;</li>
          <li>mensagens e metadados de conversas mantidas com o atendimento;</li>
          <li>
            preferências, serviços, profissionais, unidades, horários e informações necessárias ao
            agendamento;
          </li>
          <li>dados de conta dos negócios assinantes e de seus integrantes autorizados;</li>
          <li>
            registros técnicos, de segurança, auditoria, consentimento e funcionamento do serviço.
          </li>
        </ul>
        <p>
          Não solicitamos dados pessoais sensíveis que não sejam necessários ao atendimento. O
          usuário não deve enviar informações médicas, biométricas, financeiras ou outros dados
          sensíveis sem necessidade e autorização adequadas.
        </p>

        <h2>3. Finalidades e bases legais</h2>
        <p>
          Tratamos dados para prestar o atendimento solicitado, consultar disponibilidade, criar e
          administrar agendamentos, responder mensagens, prevenir fraude e abuso, manter a
          segurança, prestar suporte, cumprir obrigações legais e melhorar a confiabilidade do
          produto. Conforme o contexto, o tratamento pode se apoiar na execução de contrato ou de
          procedimentos solicitados pelo titular, no cumprimento de obrigação legal, no legítimo
          interesse com avaliação de impacto e salvaguardas, ou no consentimento.
        </p>

        <h2>4. Compartilhamento e fornecedores</h2>
        <p>
          Podemos utilizar fornecedores estritamente necessários à operação, incluindo Meta/WhatsApp
          para mensageria, Supabase para infraestrutura de dados e provedores de modelos de
          inteligência artificial. Esses fornecedores tratam dados segundo seus próprios termos,
          medidas de segurança e instruções contratuais aplicáveis. Também podemos compartilhar
          informações quando exigido por lei ou para proteger direitos e segurança.
        </p>

        <h2>5. Transferências internacionais</h2>
        <p>
          Alguns fornecedores podem processar dados fora do Brasil. Nesses casos, buscamos aplicar
          mecanismos contratuais e medidas de proteção compatíveis com a LGPD e limitar o
          compartilhamento ao necessário para a finalidade informada.
        </p>

        <h2>6. Retenção</h2>
        <p>
          Mantemos dados pelo tempo necessário para prestar o serviço, cumprir obrigações legais,
          resolver disputas e proteger a plataforma. Os prazos podem variar conforme a configuração
          do negócio contratante, a natureza do registro e requisitos legais. Ao fim da necessidade,
          os dados são excluídos, anonimizados ou mantidos de forma restrita quando houver
          fundamento legal.
        </p>

        <h2>7. Segurança</h2>
        <p>
          Adotamos controles de acesso, isolamento entre empresas, autenticação, registros de
          auditoria, proteção de segredos, criptografia em trânsito e práticas de minimização.
          Nenhum sistema é totalmente imune a incidentes; ocorrências relevantes serão tratadas
          conforme a legislação aplicável.
        </p>

        <h2>8. Direitos do titular</h2>
        <p>
          Nos termos da LGPD, o titular pode solicitar confirmação e acesso, correção, informação
          sobre compartilhamento, anonimização, bloqueio ou exclusão quando aplicável,
          portabilidade conforme regulamentação, revisão de decisões automatizadas, oposição e
          revogação do consentimento. Quando o tratamento ocorrer em nome de um negócio de beleza, a
          solicitação poderá ser encaminhada ao respectivo controlador.
        </p>

        <h2 id="exclusao">9. Exclusão de dados e contato de privacidade</h2>
        <p>
          Para exercer direitos ou solicitar a exclusão de dados, envie um e-mail para{' '}
          <a href="mailto:eddigital.oficial@gmail.com?subject=Privacidade%20e%20exclus%C3%A3o%20de%20dados%20-%20Beauty%20Agent%20SaaS">
            eddigital.oficial@gmail.com
          </a>{' '}
          com o assunto <strong>“Privacidade e exclusão de dados — Beauty Agent SaaS”</strong>.
          Informe somente os dados necessários para localizar a relação ou conversa. Poderemos
          solicitar confirmação de identidade para evitar acesso ou exclusão indevidos. Responderemos
          nos prazos aplicáveis e explicaremos eventual retenção exigida por lei. O passo a passo
          está em <a href="/exclusao-de-dados">exclusão de dados</a>.
        </p>

        <h2>10. Crianças e adolescentes</h2>
        <p>
          A plataforma não é direcionada a crianças. Negócios que atendam menores devem obter as
          autorizações necessárias e observar o melhor interesse da criança ou do adolescente.
        </p>

        <h2>11. Alterações desta política</h2>
        <p>
          Podemos atualizar esta política para refletir mudanças legais, técnicas ou operacionais. A
          versão vigente e sua data de atualização permanecerão disponíveis nesta página.
        </p>

        <footer className={styles.rodape}>
          Canal de privacidade:{' '}
          <a href="mailto:eddigital.oficial@gmail.com">eddigital.oficial@gmail.com</a>
        </footer>
      </main>
    </div>
  );
}
