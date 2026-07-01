CREATE DATABASE IF NOT EXISTS sistema_estoque;
USE sistema_estoque;

CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'root';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;

CREATE TABLE IF NOT EXISTS mercadorias (
    id_mercadoria INT(6) UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    codigo VARCHAR(6) UNIQUE,
    descricao VARCHAR(255),
    preco_unitario DECIMAL(11, 2)
);

CREATE TABLE IF NOT EXISTS estoques (
    id_estoque INT(6) UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    id_mercadoria INT(6) UNSIGNED NOT NULL UNIQUE,
    quantidade INT,
    FOREIGN KEY(id_mercadoria) REFERENCES mercadorias(id_mercadoria)
);
