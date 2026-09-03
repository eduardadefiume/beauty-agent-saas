import { subirFoto } from '../../../../lib/fotos';

export const dynamic = 'force-dynamic';

// O áudio e a foto que o dono manda no onboarding.
//
// Vão para o balde `conhecimento` e não para `clientes`: é material do salão
// falando do próprio salão -- tabela de preço, foto de referência, o dono
// contando a regra dele. Nada aqui é dado de uma pessoa atendida, e por isso
// morre com o salão, não com um pedido de exclusão de cliente.
export async function POST(request: Request): Promise<Response> {
  return subirFoto(request, 'conhecimento', 'onboarding', 'IMAGEM_OU_AUDIO');
}
