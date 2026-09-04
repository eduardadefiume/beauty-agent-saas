// UM BACKUP DE VERDADE, PEQUENO
//
// Este `msgstore.db.crypt15` não foi montado pelo código que ele testa. Ele foi
// cifrado pela wa-crypt-tools, a implementação de referência que a comunidade
// usa há anos para abrir backups do WhatsApp — a partir de um SQLite com o
// esquema real do msgstore (tabelas `message`, `chat`, `jid`, `message_media`).
//
// A diferença importa. Se o fixture saísse do meu próprio entendimento do
// formato, o teste provaria apenas que sou coerente comigo mesmo, e um erro de
// leitura do formato passaria verde. Vindo da referência, ele prova que o meu
// leitor concorda com quem já leu backups reais.
//
// Chave raiz: 00112233445566778899aabbccddeeff repetido duas vezes.
// IV: 0f0e0d0c0b0a09080706050403020100.

export const CHAVE_DO_FIXTURE = '00112233445566778899aabbccddeeff'.repeat(2);

export const CRYPT15_EM_BASE64 =
  'hgEIARoSChAPDg0MCwoJCAcGBQQDAgEAImwKCTIuMjYuMzQuNxoCMDAgASgBMAE4AUABSAFQAVgBYAFoAXABeAGAAQGIAQGQAQGYAQGgAQGoAQGwAQG4AQHAAQHIAQHQAQHYAQHgAQHoAQHwAQH4AQGAAgGIAgGQAgGYAgGgAgGoAgG4AgEwA0LN0HfywRt0bJqkwADF1DI25iYJzIZHEbWHs5PEbqSTNf4a+myZR5R2MLJFB9B4eTfpSP7v+pAcqDVXc5X19Y15IShHMtNegph65HCHHs3/ZsyLCWseeKgFUkpyF9TOSzxh6Js7AuwhzJsDrr9valte68jkpYtZVmwgEA852u1wkObyusrqJFEwU7IIGXOFu/TFrwSQmvbblho8yjZc/MPT54zFsKyOd1ofZObW9MaknveiN0/od24vQS5WHl/mKnuwmj8SkBtBy7gGAhOhRahyLMHG0ZzEKNJdrOafFhxa9wAC0gwZGmSanFTm9J4xxsNbnnFqygXjwnpshbXKPBgvRpA4ZbU2vrCEkoe4cYgaY6OVuGPJi+l2LeV1HHvH4wltQGYa45S+OmhDRh194mmbbh37VxmnjcpIYTFbLR/bEiSR3nIW6wRhWoBWwXOoM8hXAJjLtPKrA/S1qgPdnIevdz9TIBfdRV4OLZDVzgV/iuJz31SAEZT/TmxY+06RMH7FV+OmGPjXJekdkIogsKfwtkaXv43iEHxGr9uq2CCsfHF3C6xc0P+kJr57uaRL9aT+mPTCkdBp8CdryST18zV7Lffp+LA+K5P+iI5wwAbkTBibhk/Y16aQzsLxaO/AayUmcxx4rWecywyJOIY5MCpKiWeCFGQtoMeW7Z1o99Z6DHKGLMOUE3CaHbR/VfKesolppPgMsZy13Zr9f6G6c8GGetz6Rs27waKDor0VKb4MWQBCf78QRVzElapNUWHXKoRyAfuVfenHf6AnGsMpJ80as7286HZ5i7kB2vJimt/Vxj6JMzB+JDkM1q1xsBd7tN6wjXDFECk3D40Dqz54SGNRcBmSvVXoHIYAN8SYcZynJjhECRuR2MnZ3Bo8ADmzyubY9j5PEqM1S6PIEuGp6eRpkku9XVbu/PySks9XEbdroEdJzLEsoP/4KyA21Lir7INrcEt+AvFn49PFPGBz5BBnp1Szff6Zmq0Am7IBsCmYcMVBcoz1FNJZ2gQdsZAate/A+57BfoCMWWnDmB1o/Mj6xAzLexRpsCuYJ7hGFtdkTKCfeou0NvtCi0EIUi6/tcQVsit1x0u80j/Cnln2jxQIzAyccGufQKUQqiQeZGs20DGNAsNGuqc/A/dfwt9j400Cf2nZeWTGvbtUVkYDhT0zVCvbPWsH0HLGCzJaRYkXFMa3pwQ9sNga3UvB2SDvfmY=';

export function bytesDoFixture(): Uint8Array {
  return Uint8Array.from(Buffer.from(CRYPT15_EM_BASE64, 'base64'));
}
