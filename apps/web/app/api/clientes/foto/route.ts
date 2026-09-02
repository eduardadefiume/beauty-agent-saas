import { assinarFoto, subirFoto } from '../../../../lib/fotos';

export const dynamic = 'force-dynamic';

// A foto que identifica a cliente na ficha.
//
// POR QUE EXISTE. Tem mais de uma Andreia no salão. Abrir a lista e ver só o
// nome não diz qual é qual, e quem atende resolve isso pelo rosto, não pelo
// telefone. A foto aqui serve para reconhecer a pessoa -- não é foto de cabelo
// nem de resultado, que já têm lugar próprio na ficha.
//
// VAI PARA O BALDE `clientes`, e isso é uma decisão de LGPD, não de arrumação:
// foto de pessoa some quando ela pede, foto do vocabulário do salão some quando
// o salão muda a régua. No mesmo balde, "apagar os dados da fulana" viraria uma
// busca em vez de um comando.
export async function POST(request: Request): Promise<Response> {
  return subirFoto(request, 'clientes', 'perfil');
}

export async function GET(request: Request): Promise<Response> {
  return assinarFoto(request, 'clientes');
}
