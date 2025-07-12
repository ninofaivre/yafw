{ fetchFromGitHub }:
{
  zli = fetchFromGitHub {
    owner = "xcaeser";
    repo = "zli";
    rev = "v3.7.1";
    sha256 = "nG23wBOF2fvRZxbFIZ0ltvBWufDJ4Q6v5hrMj6BUh38=";
  };
}
