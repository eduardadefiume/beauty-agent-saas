import {
  assinarFotoDeReferencia,
  subirFotoDeReferencia,
} from '../../../../lib/fotos-de-referencia';

export const dynamic = 'force-dynamic';

// Fotos de referência das famílias de tom.
//
// A família de cor se define por foto: o dono sobe a imagem e diz a classe. A
// altura de tom é lida depois pelo worker, para que ninguém digite número.
export async function POST(request: Request): Promise<Response> {
  return subirFotoDeReferencia(request, 'cor');
}

export async function GET(request: Request): Promise<Response> {
  return assinarFotoDeReferencia(request);
}
