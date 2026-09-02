import { assinarFoto, subirFoto } from '../../../../lib/fotos';

export const dynamic = 'force-dynamic';

// Fotos de referência das opções do vocabulário: o que este salão chama de
// "muito volumoso", de "curto", de "fino".
//
// POR QUE FALTAVA. A tabela de fotos de referência existe desde o começo, mas
// não havia rota de upload -- a tela listava as fotos que já existiam e dizia,
// honestamente, que não dava para subir foto nova. Descrever volume em texto
// funciona mal: "ocupa mais que a largura dos ombros" quer dizer coisas
// diferentes para pessoas diferentes, e uma foto resolve a ambiguidade que
// três linhas de texto não resolvem.
export async function POST(request: Request): Promise<Response> {
  return subirFoto(request, 'conhecimento', 'conhecimento');
}

export async function GET(request: Request): Promise<Response> {
  return assinarFoto(request, 'conhecimento');
}
